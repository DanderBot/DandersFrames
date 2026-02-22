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
local max, min = math.max, math.min

-- Local references set during BuildAuraDesignerPage
local GUI
local page
local db
local Adapter

-- State
local selectedAura = nil        -- nil = Global Settings view, or aura internal name
local selectedSpec = nil         -- Current spec key being viewed
local expandedSections = {}     -- Persist expand state: expandedSections["auraName:typeKey"] = true/false

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
    Solid = "Solid", Glow = "Glow", Pulse = "Pulse",
    _order = {"Solid", "Glow", "Pulse"},
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

local function GetAuraDesignerDB()
    return db.auraDesigner
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

-- Get or resolve the active spec key from settings
local function ResolveSpec()
    local adDB = GetAuraDesignerDB()
    if adDB.spec == "auto" then
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- Ensure an aura config table exists, creating it with defaults if needed
local function EnsureAuraConfig(auraName)
    local adDB = GetAuraDesignerDB()
    if not adDB.auras[auraName] then
        adDB.auras[auraName] = {
            priority = 5,
        }
    end
    return adDB.auras[auraName]
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
                showDuration = gd.showDuration ~= false, durationFont = "Fonts\\FRIZQT__.TTF",
                durationScale = 1.0, durationOutline = "OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,
                -- Stack count
                showStacks = gd.showStacks ~= false, stackMinimum = 2,
                stackFont = "Fonts\\FRIZQT__.TTF", stackScale = 1.0,
                stackOutline = "OUTLINE", stackAnchor = "BOTTOMRIGHT",
                stackX = 0, stackY = 0,
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
                showDuration = gd.showDuration ~= false, durationFont = "Fonts\\FRIZQT__.TTF",
                durationScale = 1.0, durationOutline = "OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,
                -- Stack count
                showStacks = gd.showStacks ~= false, stackMinimum = 2,
                stackFont = "Fonts\\FRIZQT__.TTF", stackScale = 1.0,
                stackOutline = "OUTLINE", stackAnchor = "BOTTOMRIGHT",
                stackX = 0, stackY = 0,
            }
        elseif typeKey == "bar" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "BOTTOM", offsetX = 0, offsetY = 0,
                -- Size & orientation
                orientation = "HORIZONTAL", width = 60, height = 6,
                matchFrameWidth = true, matchFrameHeight = false,
                -- Colors & border
                fillColor = {r = 1, g = 1, b = 1, a = 1},
                bgColor = {r = 0, g = 0, b = 0, a = 0.5},
                showBorder = true, borderThickness = 1,
                borderColor = {r = 0, g = 0, b = 0, a = 1}, alpha = 1.0,
            }
        elseif typeKey == "border" then
            auraCfg[typeKey] = {
                style = "Solid", color = {r = 1, g = 1, b = 1, a = 1},
                thickness = 2, pulsate = false, speed = 0.5,
            }
        elseif typeKey == "healthbar" then
            auraCfg[typeKey] = {
                mode = "Tint", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
            }
        elseif typeKey == "nametext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
            }
        elseif typeKey == "healthtext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
            }
        elseif typeKey == "framealpha" then
            auraCfg[typeKey] = {
                alpha = 0.5,
            }
        end
    end
    return auraCfg[typeKey]
end

-- Forward declaration: lightweight preview refresh (defined after RefreshPreviewEffects)
-- Called from proxy __newindex so every setting change updates the preview in real-time
local RefreshPreviewLightweight

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
    },
    square = {
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        size = 10, scale = 1.0, alpha = 1.0,
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
    },
    bar = {
        anchor = "BOTTOM", offsetX = 0, offsetY = 0,
        orientation = "HORIZONTAL", width = 60, height = 6,
        matchFrameWidth = true, matchFrameHeight = false,
        fillColor = {r = 1, g = 1, b = 1, a = 1},
        bgColor = {r = 0, g = 0, b = 0, a = 0.5},
        showBorder = true, borderThickness = 1,
        borderColor = {r = 0, g = 0, b = 0, a = 1}, alpha = 1.0,
    },
}

-- Create a proxy table that maps flat key access to nested aura config
local function CreateProxy(auraName, typeKey)
    local defaults = TYPE_DEFAULTS[typeKey]
    return setmetatable({}, {
        __index = function(_, k)
            local adDB = GetAuraDesignerDB()
            local auraCfg = adDB.auras[auraName]
            if auraCfg and auraCfg[typeKey] then
                local val = auraCfg[typeKey][k]
                if val ~= nil then return val end
            end
            -- Fall back to defaults for missing keys
            if defaults then return defaults[k] end
            return nil
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
            local adDB = GetAuraDesignerDB()
            local auraCfg = adDB.auras[auraName]
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

-- Create a proxy for the expiring sub-table
local function CreateExpiringProxy(auraName)
    return setmetatable({}, {
        __index = function(_, k)
            local adDB = GetAuraDesignerDB()
            local auraCfg = adDB.auras[auraName]
            if auraCfg and auraCfg.expiring then
                return auraCfg.expiring[k]
            end
            return nil
        end,
        __newindex = function(_, k, v)
            local auraCfg = EnsureAuraConfig(auraName)
            if not auraCfg.expiring then
                auraCfg.expiring = {
                    enabled = false, threshold = 30,
                    borderEnabled = false, borderColor = {r = 1, g = 0.53, b = 0, a = 1},
                    borderThickness = 1, pulsate = false,
                    tintEnabled = false, tintColor = {r = 1, g = 0.3, b = 0.3, a = 0.5},
                }
            end
            auraCfg.expiring[k] = v
            if RefreshPreviewLightweight then RefreshPreviewLightweight() end
        end,
    })
end

-- Get spell icon texture for an aura
local function GetAuraIcon(specKey, auraName)
    local spellIDs = DF.AuraDesigner.SpellIDs
    if not spellIDs or not specKey then return nil end
    local specIDs = spellIDs[specKey]
    if not specIDs then return nil end
    local spellID = specIDs[auraName]
    if not spellID or spellID == 0 then return nil end
    -- Use modern API first, fall back to legacy
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    elseif GetSpellTexture then
        return GetSpellTexture(spellID)
    end
    return nil
end

-- Count active effects for an aura
local function CountActiveEffects(auraName)
    local adDB = GetAuraDesignerDB()
    local auraCfg = adDB.auras[auraName]
    if not auraCfg then return 0 end
    local count = 0
    for _, typeDef in ipairs(INDICATOR_TYPES) do
        if auraCfg[typeDef.key] then count = count + 1 end
    end
    return count
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
local leftPanel           -- Left content area (flexible width)
local rightPanel          -- Right settings panel (280px fixed)
local tileStripHeader     -- Header bar for tile strip (stores countLabel)
local enableBanner        -- Enable toggle banner
local attributionRow      -- HARF attribution row
local tileStrip           -- Horizontal scrolling aura tile palette
local tileStripContent    -- ScrollChild for tile strip
local framePreview        -- Mock unit frame preview
local activeEffectsStrip  -- Active effects list below preview
local dragHintText        -- Dynamic hint text below frame preview
local rightScrollFrame    -- Scroll frame for right panel content
local rightScrollChild    -- ScrollChild for right panel

-- Tile button pool
local tilePool = {}
local activeTiles = {}

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

local function StartDrag(auraName, auraInfo, specKey)
    if dragState.isDragging then return end

    dragState.isDragging = true
    dragState.auraName = auraName
    dragState.auraInfo = auraInfo
    dragState.specKey = specKey
    dragState.dropAnchor = nil

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

    -- Enlarge all anchor dots to signal they are drop targets
    for _, dotFrame in pairs(anchorDots) do
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

EndDrag = function()
    if not dragState.isDragging then return end

    local auraName = dragState.auraName
    local dropAnchor = dragState.dropAnchor

    -- Clear state
    dragState.isDragging = false
    dragState.auraName = nil
    dragState.auraInfo = nil
    dragState.specKey = nil
    dragState.dropAnchor = nil

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

    -- Reset anchor dots to default
    for _, dotFrame in pairs(anchorDots) do
        dotFrame.dot:SetSize(6, 6)
        dotFrame.dot:SetColorTexture(0.45, 0.45, 0.95, 0.3)
    end

    -- Process the drop
    if auraName and dropAnchor then
        -- Enable Icon type at this anchor (or update existing)
        local typeCfg = EnsureTypeConfig(auraName, "icon")
        typeCfg.anchor = dropAnchor

        -- Select the aura
        selectedAura = auraName
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

    -- Iterate all configured auras, find placed types with anchors
    for auraName, auraCfg in pairs(adDB.auras) do
        local info = infoLookup[auraName]
        if info then
            for _, typeDef in ipairs(INDICATOR_TYPES) do
                if typeDef.placed and auraCfg[typeDef.key] then
                    local typeCfg = auraCfg[typeDef.key]
                    local Indicators = DF.AuraDesigner and DF.AuraDesigner.Indicators
                    local capturedAura = auraName

                    if typeDef.key == "icon" and Indicators then
                        -- Build mock aura data with the spell's texture
                        local tex = GetAuraIcon(spec, auraName)
                        local mockAuraData = {
                            spellId = info.spellIds and info.spellIds[1] or 0,
                            icon = tex,
                            duration = 15,
                            expirationTime = GetTime() + 10,
                            stacks = 3,
                        }
                        -- Use the real indicator renderer (identical to runtime)
                        Indicators:ApplyIcon(mockFrame, typeCfg, mockAuraData, adDB.defaults, auraName)

                        -- Retrieve the icon to set up preview interactivity
                        local iconMap = mockFrame.dfAD_icons
                        local icon = iconMap and iconMap[auraName]
                        if icon then
                            icon:SetFrameLevel(mockFrame:GetFrameLevel() + 8)
                            -- Re-enable mouse for preview click handlers
                            icon:EnableMouse(true)
                            if icon.SetMouseClickEnabled then
                                icon:SetMouseClickEnabled(true)
                            end
                            icon:SetScript("OnMouseUp", function(_, button)
                                if button == "RightButton" then
                                    local cfg = adDB.auras[capturedAura]
                                    if cfg then cfg.icon = nil end
                                    DF:AuraDesigner_RefreshPage()
                                elseif button == "LeftButton" then
                                    selectedAura = capturedAura
                                    DF:AuraDesigner_RefreshPage()
                                end
                            end)
                            tinsert(placedIndicators, icon)
                        end

                    elseif typeDef.key == "square" and Indicators then
                        -- Build mock aura data for square
                        local mockAuraData = {
                            spellId = info.spellIds and info.spellIds[1] or 0,
                            icon = GetAuraIcon(spec, auraName),
                            duration = 0,
                            stacks = 3,
                        }
                        Indicators:ApplySquare(mockFrame, typeCfg, mockAuraData, adDB.defaults, auraName)

                        local sqMap = mockFrame.dfAD_squares
                        local sq = sqMap and sqMap[auraName]
                        if sq then
                            sq:SetFrameLevel(mockFrame:GetFrameLevel() + 8)
                            sq:EnableMouse(true)
                            sq:SetScript("OnMouseUp", function(_, button)
                                if button == "RightButton" then
                                    local cfg = adDB.auras[capturedAura]
                                    if cfg then cfg.square = nil end
                                    DF:AuraDesigner_RefreshPage()
                                elseif button == "LeftButton" then
                                    selectedAura = capturedAura
                                    DF:AuraDesigner_RefreshPage()
                                end
                            end)
                            tinsert(placedIndicators, sq)
                        end

                    elseif typeDef.key == "bar" and Indicators then
                        -- Build mock aura data for bar
                        local mockAuraData = {
                            spellId = info.spellIds and info.spellIds[1] or 0,
                            icon = GetAuraIcon(spec, auraName),
                            duration = 15,
                            expirationTime = GetTime() + 10,
                            stacks = 0,
                        }
                        Indicators:ApplyBar(mockFrame, typeCfg, mockAuraData, adDB.defaults, auraName)

                        local barMap = mockFrame.dfAD_bars
                        local bar = barMap and barMap[auraName]
                        if bar then
                            bar:SetFrameLevel(mockFrame:GetFrameLevel() + 7)
                            bar:EnableMouse(true)
                            bar:SetScript("OnMouseUp", function(_, button)
                                if button == "RightButton" then
                                    local cfg = adDB.auras[capturedAura]
                                    if cfg then cfg.bar = nil end
                                    DF:AuraDesigner_RefreshPage()
                                elseif button == "LeftButton" then
                                    selectedAura = capturedAura
                                    DF:AuraDesigner_RefreshPage()
                                end
                            end)
                            tinsert(placedIndicators, bar)
                        end
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
    if framePreview.borderOverlay then
        framePreview.borderOverlay:Hide()
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

    -- If no aura selected, stay at defaults
    if not selectedAura then return end

    local adDB = GetAuraDesignerDB()
    local auraCfg = adDB.auras[selectedAura]
    if not auraCfg then return end

    -- Border effect
    if auraCfg.border then
        local clr = auraCfg.border.color or {r = 1, g = 1, b = 1, a = 1}
        local thickness = auraCfg.border.thickness or 2
        local overlay = framePreview.borderOverlay
        if not overlay.SetBackdrop then Mixin(overlay, BackdropTemplateMixin) end
        overlay:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = thickness,
        })
        overlay:SetBackdropBorderColor(clr.r, clr.g, clr.b, clr.a or 1)
        overlay:Show()
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

    -- Re-apply placed indicators using current settings (frames already exist)
    if mockFrame.dfAD_icons then
        for auraName, icon in pairs(mockFrame.dfAD_icons) do
            local auraCfg = adDB.auras and adDB.auras[auraName]
            if auraCfg and auraCfg.icon then
                local tex = GetAuraIcon(spec, auraName)
                local mockAuraData = {
                    spellId = 0, icon = tex,
                    duration = 15, expirationTime = GetTime() + 10,
                    stacks = 3,
                }
                Indicators:ApplyIcon(mockFrame, auraCfg.icon, mockAuraData, adDB.defaults, auraName)
            end
        end
    end

    if mockFrame.dfAD_squares then
        for auraName, sq in pairs(mockFrame.dfAD_squares) do
            local auraCfg = adDB.auras and adDB.auras[auraName]
            if auraCfg and auraCfg.square then
                local mockAuraData = {
                    spellId = 0, icon = nil, duration = 0, stacks = 3,
                }
                Indicators:ApplySquare(mockFrame, auraCfg.square, mockAuraData, adDB.defaults, auraName)
            end
        end
    end

    if mockFrame.dfAD_bars then
        for auraName, bar in pairs(mockFrame.dfAD_bars) do
            local auraCfg = adDB.auras and adDB.auras[auraName]
            if auraCfg and auraCfg.bar then
                local mockAuraData = {
                    spellId = 0, icon = nil,
                    duration = 15, expirationTime = GetTime() + 10,
                    stacks = 0,
                }
                Indicators:ApplyBar(mockFrame, auraCfg.bar, mockAuraData, adDB.defaults, auraName)
            end
        end
    end

    -- Also refresh frame-level preview effects (border, healthbar color, text colors, alpha)
    RefreshPreviewEffects()
end

-- ============================================================
-- TILE STRIP
-- ============================================================

local function CreateAuraTile(parent, auraInfo, index)
    local TILE_W, ICON_SZ = 68, 56
    local tile = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tile:SetSize(TILE_W, ICON_SZ + 18)  -- icon + name row
    -- No backdrop on tile itself, icon carries the visual

    -- Icon area (colored square as placeholder until real spell icons)
    tile.iconBg = CreateFrame("Frame", nil, tile, "BackdropTemplate")
    tile.iconBg:SetPoint("TOP", 0, 0)
    tile.iconBg:SetSize(ICON_SZ, ICON_SZ)
    if not tile.iconBg.SetBackdrop then Mixin(tile.iconBg, BackdropTemplateMixin) end
    tile.iconBg:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    tile.iconBg:SetBackdropColor(auraInfo.color[1] * 0.25, auraInfo.color[2] * 0.25, auraInfo.color[3] * 0.25, 1)
    tile.iconBg:SetBackdropBorderColor(0.27, 0.27, 0.27, 1)

    -- Spell icon texture (with letter fallback)
    local spec = ResolveSpec()
    local iconTex = GetAuraIcon(spec, auraInfo.name)

    tile.icon = tile.iconBg:CreateTexture(nil, "ARTWORK")
    tile.icon:SetPoint("TOPLEFT", 2, -2)
    tile.icon:SetPoint("BOTTOMRIGHT", -2, 2)

    if iconTex then
        tile.icon:SetTexture(iconTex)
        tile.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- trim icon borders
    else
        -- Fallback: colored square with first letter
        tile.icon:SetColorTexture(auraInfo.color[1] * 0.3, auraInfo.color[2] * 0.3, auraInfo.color[3] * 0.3, 1)
    end

    -- Fallback letter (shown if no spell icon available)
    tile.letter = tile.iconBg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tile.letter:SetPoint("CENTER", 0, 0)
    tile.letter:SetText(auraInfo.display:sub(1, 1))
    tile.letter:SetTextColor(auraInfo.color[1], auraInfo.color[2], auraInfo.color[3])
    if iconTex then
        tile.letter:Hide()  -- hide letter when we have a real icon
    end

    -- Name label
    tile.nameLabel = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tile.nameLabel:SetPoint("TOP", tile.iconBg, "BOTTOM", 0, -3)
    tile.nameLabel:SetWidth(TILE_W)
    tile.nameLabel:SetMaxLines(1)
    tile.nameLabel:SetText(auraInfo.display)
    tile.nameLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Configured badge (bottom-right of icon)
    tile.badge = tile.iconBg:CreateFontString(nil, "OVERLAY")
    tile.badge:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
    tile.badge:SetPoint("BOTTOMRIGHT", tile.iconBg, "BOTTOMRIGHT", -2, 2)
    tile.badge:SetText("")
    tile.badge:SetTextColor(1, 1, 1)
    tile.badge:Hide()

    -- Badge background (small accent pill)
    tile.badgeBg = tile.iconBg:CreateTexture(nil, "ARTWORK", nil, 1)
    tile.badgeBg:SetPoint("CENTER", tile.badge, "CENTER", 0, 0)
    tile.badgeBg:SetSize(14, 12)
    local tc = GetThemeColor()
    tile.badgeBg:SetColorTexture(tc.r, tc.g, tc.b, 0.85)
    tile.badgeBg:Hide()

    -- Glow overlay (simulates box-shadow for selected/configured state)
    tile.glow = tile:CreateTexture(nil, "BACKGROUND")
    tile.glow:SetPoint("TOPLEFT", tile.iconBg, "TOPLEFT", -4, 4)
    tile.glow:SetPoint("BOTTOMRIGHT", tile.iconBg, "BOTTOMRIGHT", 4, -4)
    tile.glow:SetColorTexture(0, 0, 0, 0)  -- invisible by default
    tile.glow:Hide()

    tile.auraInfo = auraInfo
    tile.auraName = auraInfo.name

    tile.SetSelected = function(self, selected)
        local c = GetThemeColor()
        if selected then
            self.iconBg:SetBackdropBorderColor(c.r, c.g, c.b, 1)
            self.glow:SetColorTexture(c.r, c.g, c.b, 0.25)
            self.glow:Show()
        else
            local adDB = GetAuraDesignerDB()
            local auraCfg = adDB.auras[self.auraName]
            if auraCfg then
                -- Configured: accent border, subtle glow
                self.iconBg:SetBackdropBorderColor(c.r, c.g, c.b, 0.6)
                self.glow:SetColorTexture(c.r, c.g, c.b, 0.15)
                self.glow:Show()
            else
                self.iconBg:SetBackdropBorderColor(0.27, 0.27, 0.27, 1)
                self.glow:Hide()
            end
        end
    end

    tile.UpdateBadge = function(self)
        local count = CountActiveEffects(self.auraName)
        if count > 0 then
            self.badge:SetText(count)
            self.badge:Show()
            self.badgeBg:Show()
        else
            self.badge:Hide()
            self.badgeBg:Hide()
        end
    end

    tile:SetScript("OnEnter", function(self)
        if selectedAura ~= self.auraName and not dragState.isDragging then
            local c = GetThemeColor()
            self.iconBg:SetBackdropBorderColor(c.r, c.g, c.b, 0.8)
        end
    end)
    tile:SetScript("OnLeave", function(self)
        if not dragState.isDragging then
            self:SetSelected(selectedAura == self.auraName)
        end
    end)

    tile:SetScript("OnClick", function(self)
        selectedAura = self.auraName
        DF:AuraDesigner_RefreshPage()
    end)

    -- Drag support: drag aura tile onto frame preview to place at anchor
    tile:RegisterForDrag("LeftButton")
    tile:SetScript("OnDragStart", function(self)
        local spec = ResolveSpec()
        if spec then
            StartDrag(self.auraName, self.auraInfo, spec)
        end
    end)

    return tile
end

local function CreateGlobalSettingsTile(parent)
    local TILE_W, ICON_SZ = 68, 56
    local tile = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tile:SetSize(TILE_W, ICON_SZ + 18)

    -- Icon area (dashed border effect via backdrop)
    tile.iconBg = CreateFrame("Frame", nil, tile, "BackdropTemplate")
    tile.iconBg:SetPoint("TOP", 0, 0)
    tile.iconBg:SetSize(ICON_SZ, ICON_SZ)
    if not tile.iconBg.SetBackdrop then Mixin(tile.iconBg, BackdropTemplateMixin) end
    tile.iconBg:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    tile.iconBg:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    tile.iconBg:SetBackdropBorderColor(0.40, 0.40, 0.40, 1)

    -- Gear/cog icon
    tile.letter = tile.iconBg:CreateFontString(nil, "OVERLAY")
    tile.letter:SetFont("Fonts\\FRIZQT__.TTF", 22, "")
    tile.letter:SetPoint("CENTER", 0, 0)
    tile.letter:SetText("\226\154\153")  -- UTF-8 gear icon ⚙
    tile.letter:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    tile.nameLabel = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tile.nameLabel:SetPoint("TOP", tile.iconBg, "BOTTOM", 0, -3)
    tile.nameLabel:SetWidth(TILE_W)
    tile.nameLabel:SetMaxLines(1)
    tile.nameLabel:SetText("Global Settings")
    tile.nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    tile.auraName = nil
    tile.UpdateBadge = function() end  -- No badge for global

    tile.SetSelected = function(self, isSelected)
        if isSelected then
            local c = GetThemeColor()
            self.iconBg:SetBackdropBorderColor(c.r, c.g, c.b, 1)
        else
            self.iconBg:SetBackdropBorderColor(0.40, 0.40, 0.40, 1)
        end
    end

    tile:SetScript("OnEnter", function(self)
        if selectedAura ~= nil then
            self.iconBg:SetBackdropBorderColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
        end
    end)
    tile:SetScript("OnLeave", function(self)
        self:SetSelected(selectedAura == nil)
    end)

    tile:SetScript("OnClick", function(self)
        selectedAura = nil
        DF:AuraDesigner_RefreshPage()
    end)

    return tile
end

-- ============================================================
-- TILE STRIP POPULATION
-- ============================================================

local function PopulateTileStrip()
    for _, tile in ipairs(activeTiles) do
        tile:Hide()
    end
    wipe(activeTiles)

    if not tileStripContent then return end

    local spec = ResolveSpec()
    selectedSpec = spec

    if not spec then return end

    local auras = Adapter:GetTrackableAuras(spec)
    if not auras or #auras == 0 then return end

    local TILE_GAP = 6
    local TILE_PAD = 10  -- left/right padding inside strip

    local globalTile = CreateGlobalSettingsTile(tileStripContent)
    globalTile:SetPoint("LEFT", tileStripContent, "LEFT", TILE_PAD, 0)
    globalTile:SetSelected(selectedAura == nil)
    activeTiles[#activeTiles + 1] = globalTile

    local prevTile = globalTile
    for i, auraInfo in ipairs(auras) do
        local tile = CreateAuraTile(tileStripContent, auraInfo, i)
        tile:SetPoint("LEFT", prevTile, "RIGHT", TILE_GAP, 0)
        tile:SetSelected(selectedAura == auraInfo.name)
        tile:UpdateBadge()
        activeTiles[#activeTiles + 1] = tile
        prevTile = tile
    end

    local totalWidth = TILE_PAD + (#auras + 1) * (68 + TILE_GAP) + TILE_PAD
    tileStripContent:SetWidth(totalWidth)

    -- Update tile strip header count
    if tileStripHeader and tileStripHeader.countLabel then
        tileStripHeader.countLabel:SetText(tostring(#auras))
    end
end

-- ============================================================
-- RIGHT PANEL: INDICATOR TYPE SECTION BUILDER
-- Builds a collapsible section for one indicator type
-- ============================================================

local function AddSectionHeader(parent, yOffset, label, typeKey, auraName, width)
    local headerHeight = 28
    local header = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    header:SetSize(width or 258, headerHeight)
    header:SetPoint("TOPLEFT", 0, yOffset)
    ApplyBackdrop(header, C_PANEL, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    -- Enable checkbox
    local cb = CreateFrame("CheckButton", nil, header, "BackdropTemplate")
    cb:SetSize(16, 16)
    cb:SetPoint("LEFT", 6, 0)
    ApplyBackdrop(cb, C_ELEMENT, C_BORDER)

    cb.Check = cb:CreateTexture(nil, "OVERLAY")
    cb.Check:SetTexture("Interface\\Buttons\\WHITE8x8")
    local tc = GetThemeColor()
    cb.Check:SetVertexColor(tc.r, tc.g, tc.b)
    cb.Check:SetPoint("CENTER")
    cb.Check:SetSize(8, 8)
    cb:SetCheckedTexture(cb.Check)

    local adDB = GetAuraDesignerDB()
    local auraCfg = adDB.auras[auraName]
    cb:SetChecked(auraCfg and auraCfg[typeKey] ~= nil)

    -- Collapse/expand arrow
    header.arrow = header:CreateTexture(nil, "OVERLAY")
    header.arrow:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    header.arrow:SetSize(10, 10)
    header.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    header.arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Title
    local title = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("LEFT", header.arrow, "RIGHT", 4, 0)
    title:SetText(label)
    title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- State
    header.expanded = false
    header.contentFrame = nil
    header.typeKey = typeKey
    header.auraName = auraName

    return header, cb
end

-- Build the widget content for a given indicator type
local function BuildTypeContent(parent, typeKey, auraName, width)
    local proxy = CreateProxy(auraName, typeKey)
    local contentWidth = width or 248
    local widgets = {}
    local totalHeight = 8  -- top padding

    local function AddWidget(widget, height)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -totalHeight)
        if widget.SetWidth then widget:SetWidth(contentWidth - 10) end
        tinsert(widgets, widget)
        totalHeight = totalHeight + (height or 30)
    end

    local function AddDivider()
        totalHeight = totalHeight + 4
        local div = parent:CreateTexture(nil, "ARTWORK")
        div:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -totalHeight)
        div:SetSize(contentWidth - 20, 1)
        div:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.4)
        totalHeight = totalHeight + 6
    end

    if typeKey == "icon" then
        -- Placement
        AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
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
        AddWidget(GUI:CreateDropdown(parent, "Duration Font", DF:GetFontList(), proxy, "durationFont"), 54)
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
        AddWidget(GUI:CreateDropdown(parent, "Stack Font", DF:GetFontList(), proxy, "stackFont"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Scale", 0.5, 2.0, 0.1, proxy, "stackScale"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Stack Outline", OUTLINE_OPTIONS, proxy, "stackOutline"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Stack Anchor", ANCHOR_OPTIONS, proxy, "stackAnchor"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Offset X", -20, 20, 1, proxy, "stackX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Offset Y", -20, 20, 1, proxy, "stackY"), 54)

    elseif typeKey == "square" then
        -- Placement
        AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
        AddDivider()
        -- Sizing & appearance
        AddWidget(GUI:CreateSlider(parent, "Size", 4, 32, 1, proxy, "size"), 54)
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
        AddWidget(GUI:CreateDropdown(parent, "Duration Font", DF:GetFontList(), proxy, "durationFont"), 54)
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
        AddWidget(GUI:CreateDropdown(parent, "Stack Font", DF:GetFontList(), proxy, "stackFont"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Scale", 0.5, 2.0, 0.1, proxy, "stackScale"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Stack Outline", OUTLINE_OPTIONS, proxy, "stackOutline"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Stack Anchor", ANCHOR_OPTIONS, proxy, "stackAnchor"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Offset X", -20, 20, 1, proxy, "stackX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Offset Y", -20, 20, 1, proxy, "stackY"), 54)

    elseif typeKey == "bar" then
        -- Placement
        AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
        AddDivider()
        -- Size & orientation
        AddWidget(GUI:CreateDropdown(parent, "Orientation", BAR_ORIENT_OPTIONS, proxy, "orientation"), 54)
        AddWidget(GUI:CreateSlider(parent, "Width", 0, 200, 1, proxy, "width"), 54)
        AddWidget(GUI:CreateSlider(parent, "Height", 1, 30, 1, proxy, "height"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Match Frame Width", proxy, "matchFrameWidth"), 28)
        AddWidget(GUI:CreateCheckbox(parent, "Match Frame Height", proxy, "matchFrameHeight"), 28)
        AddDivider()
        -- Colors & border
        AddWidget(GUI:CreateColorPicker(parent, "Fill Color", proxy, "fillColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateColorPicker(parent, "Background Color", proxy, "bgColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateCheckbox(parent, "Show Border", proxy, "showBorder"), 28)
        AddWidget(GUI:CreateSlider(parent, "Border Thickness", 1, 4, 1, proxy, "borderThickness"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Border Color", proxy, "borderColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)

    elseif typeKey == "border" then
        AddWidget(GUI:CreateDropdown(parent, "Style", BORDER_STYLE_OPTIONS, proxy, "style"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateSlider(parent, "Thickness", 1, 8, 1, proxy, "thickness"), 54)
        AddDivider()
        AddWidget(GUI:CreateCheckbox(parent, "Pulsate", proxy, "pulsate"), 28)
        AddWidget(GUI:CreateSlider(parent, "Pulse Speed", 0.1, 2.0, 0.1, proxy, "speed"), 54)

    elseif typeKey == "healthbar" then
        AddWidget(GUI:CreateDropdown(parent, "Mode", HEALTHBAR_MODE_OPTIONS, proxy, "mode"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateSlider(parent, "Blend %", 0, 1, 0.05, proxy, "blend"), 54)

    elseif typeKey == "nametext" then
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)

    elseif typeKey == "healthtext" then
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)

    elseif typeKey == "framealpha" then
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)
    end

    totalHeight = totalHeight + 4  -- bottom padding
    parent:SetHeight(totalHeight)
    return widgets, totalHeight
end

-- ============================================================
-- RIGHT PANEL CONTENT
-- ============================================================

local rightPanelChildren = {}

local function BuildGlobalView(parent)
    local adDB = GetAuraDesignerDB()
    local defaults = adDB.defaults
    local yPos = -8
    local contentWidth = 258
    local c = GetThemeColor()

    -- Title
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, yPos)
    title:SetText("Global Defaults")
    title:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 18

    -- Sliders section label
    local defaultIconLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    defaultIconLabel:SetPoint("TOPLEFT", 10, yPos)
    defaultIconLabel:SetText("Default Icon Size")
    defaultIconLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    yPos = yPos - 4

    local iconSize = GUI:CreateSlider(parent, "Icon Size", 8, 64, 1, defaults, "iconSize")
    iconSize:SetPoint("TOPLEFT", 5, yPos)
    iconSize:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local defaultScaleLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    defaultScaleLabel:SetPoint("TOPLEFT", 10, yPos)
    defaultScaleLabel:SetText("Default Scale")
    defaultScaleLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    yPos = yPos - 4

    local iconScale = GUI:CreateSlider(parent, "Scale", 0.5, 3.0, 0.05, defaults, "iconScale")
    iconScale:SetPoint("TOPLEFT", 5, yPos)
    iconScale:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local showDuration = GUI:CreateCheckbox(parent, "Show Duration", defaults, "showDuration")
    showDuration:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 24

    local showStacks = GUI:CreateCheckbox(parent, "Show Stack Count", defaults, "showStacks")
    showStacks:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    -- ===== IMPORT FROM BUFFS TAB =====
    local div0 = parent:CreateTexture(nil, "ARTWORK")
    div0:SetPoint("TOPLEFT", 10, yPos)
    div0:SetSize(238, 1)
    div0:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 10

    local importTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    importTitle:SetPoint("TOPLEFT", 10, yPos)
    importTitle:SetText("Import from Buffs Tab")
    importTitle:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 18

    local importDesc = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    importDesc:SetPoint("TOPLEFT", 10, yPos)
    importDesc:SetWidth(238)
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
            itemLabel:SetText("|cff55cc55\226\156\147|r  " .. item[2])
        else
            itemLabel:SetText("|cffcc5555\195\151|r  " .. item[2])
        end
        itemLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        yPos = yPos - 16
    end
    yPos = yPos - 6

    -- Import button
    local importBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    importBtn:SetSize(238, 26)
    importBtn:SetPoint("TOPLEFT", 10, yPos)
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
    divider:SetSize(238, 1)
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
    copyBtn:SetSize(238, 26)
    copyBtn:SetPoint("TOPLEFT", 10, yPos)
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
    resetBtn:SetSize(238, 26)
    resetBtn:SetPoint("TOPLEFT", 10, yPos)
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

local function BuildPerAuraView(parent, auraName)
    local auraInfo
    local spec = ResolveSpec()
    if spec then
        for _, info in ipairs(Adapter:GetTrackableAuras(spec)) do
            if info.name == auraName then
                auraInfo = info
                break
            end
        end
    end
    if not auraInfo then return end

    local adDB = GetAuraDesignerDB()
    local auraCfg = adDB.auras[auraName]
    local yPos = -6
    local contentWidth = 258

    -- ===== INTRO PARAGRAPH =====
    local introText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    introText:SetPoint("TOPLEFT", 10, yPos)
    introText:SetWidth(contentWidth - 20)
    introText:SetText("Configure how this aura appears when active on a unit frame.")
    introText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    introText:SetJustifyH("LEFT")
    yPos = yPos - 18

    -- ===== DIVIDER =====
    local div1 = parent:CreateTexture(nil, "ARTWORK")
    div1:SetPoint("TOPLEFT", 10, yPos)
    div1:SetSize(238, 1)
    div1:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 8

    -- ===== 8 INDICATOR TYPE SECTIONS =====
    -- Each section: collapsible header with enable checkbox + content
    -- Placed types (icon/square/bar) first, then frame-level types
    local sectionStates = {}
    local placedCount = 0

    for _, typeDef in ipairs(INDICATOR_TYPES) do
        -- Insert separator between placed types and frame-level types
        if not typeDef.placed and placedCount > 0 then
            yPos = yPos - 2
            local sepLine = parent:CreateTexture(nil, "ARTWORK")
            sepLine:SetPoint("TOPLEFT", 0, yPos)
            sepLine:SetSize(contentWidth, 1)
            sepLine:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
            yPos = yPos - 4
            placedCount = -1  -- only insert once
        end
        if typeDef.placed then placedCount = placedCount + 1 end
        local typeKey = typeDef.key
        local typeLabel = typeDef.label
        local isEnabled = auraCfg and auraCfg[typeKey] ~= nil

        -- Section header (mockup .fx-ghdr style: element bg, border, clear visibility)
        local header = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        header:SetHeight(26)
        header:SetPoint("TOPLEFT", 0, yPos)
        header:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
        ApplyBackdrop(header, C_ELEMENT, C_BORDER)

        -- Chevron arrow (text-based, left side)
        local chevron = header:CreateFontString(nil, "OVERLAY")
        chevron:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
        chevron:SetPoint("LEFT", 8, 0)
        chevron:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        -- Title label (after chevron)
        local title = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        title:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
        title:SetText(typeLabel)

        -- Enable checkbox (13x13, right side — matches mockup layout)
        local cb = CreateFrame("CheckButton", nil, header, "BackdropTemplate")
        cb:SetSize(13, 13)
        cb:SetPoint("RIGHT", -8, 0)
        cb:SetFrameLevel(header:GetFrameLevel() + 5)
        ApplyBackdrop(cb, C_ELEMENT, C_BORDER)

        cb.Check = cb:CreateTexture(nil, "OVERLAY")
        cb.Check:SetTexture("Interface\\Buttons\\WHITE8x8")
        cb.Check:SetVertexColor(1, 1, 1)  -- white checkmark
        cb.Check:SetPoint("CENTER")
        cb.Check:SetSize(7, 7)
        cb:SetCheckedTexture(cb.Check)
        cb:SetChecked(isEnabled)

        -- Update checkbox + title appearance based on state
        local function UpdateSectionStyle()
            local tc = GetThemeColor()
            if cb:GetChecked() then
                cb:SetBackdropColor(tc.r, tc.g, tc.b, 1)
                cb:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
                title:SetTextColor(tc.r, tc.g, tc.b)  -- accent color when enabled
            else
                cb:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
                cb:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)
                title:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            end
        end
        UpdateSectionStyle()

        -- Content container (below header, hidden by default)
        local content = CreateFrame("Frame", nil, parent)
        content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
        content:SetWidth(contentWidth)
        content:Hide()

        -- Expand/collapse state (persisted across rebuilds)
        local stateKey = auraName .. ":" .. typeKey
        local expanded = expandedSections[stateKey] or false

        local function UpdateChevron()
            if expanded and isEnabled then
                chevron:SetText("\226\150\188")  -- ▼
            else
                chevron:SetText("\226\150\182")  -- ▶
            end
        end
        UpdateChevron()

        -- Build content if enabled
        local contentHeight = 0
        if isEnabled then
            local _, h = BuildTypeContent(content, typeKey, auraName, contentWidth)
            contentHeight = h
        end

        -- Store section state for layout calculation
        local sectionData = {
            header = header,
            content = content,
            contentHeight = contentHeight,
            expanded = expanded,
            enabled = isEnabled,
        }
        tinsert(sectionStates, sectionData)

        yPos = yPos - 28  -- header height + gap

        -- Click header to toggle expand (with hover highlight)
        local headerClick = CreateFrame("Button", nil, header)
        headerClick:SetAllPoints()
        headerClick:SetFrameLevel(header:GetFrameLevel() + 2)
        headerClick:RegisterForClicks("LeftButtonUp")
        headerClick:SetScript("OnEnter", function()
            header:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        end)
        headerClick:SetScript("OnLeave", function()
            header:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        end)
        headerClick:SetScript("OnClick", function()
            if not isEnabled then return end
            expanded = not expanded
            expandedSections[stateKey] = expanded
            sectionData.expanded = expanded
            if expanded then
                content:Show()
            else
                content:Hide()
            end
            UpdateChevron()
            DF:AuraDesigner_RefreshPage()
        end)

        -- Checkbox click to enable/disable type
        cb:SetScript("OnClick", function(self)
            local checked = self:GetChecked()
            UpdateSectionStyle()
            local cfg = EnsureAuraConfig(auraName)
            if checked then
                EnsureTypeConfig(auraName, typeKey)
                isEnabled = true
                sectionData.enabled = true
                -- Auto-expand when enabling
                expanded = true
                expandedSections[stateKey] = true
                sectionData.expanded = true
                -- Rebuild content
                local _, h = BuildTypeContent(content, typeKey, auraName, contentWidth)
                contentHeight = h
                sectionData.contentHeight = h
                content:Show()
            else
                cfg[typeKey] = nil
                isEnabled = false
                sectionData.enabled = false
                expanded = false
                expandedSections[stateKey] = false
                sectionData.expanded = false
                content:Hide()
            end
            UpdateChevron()
            DF:AuraDesigner_RefreshPage()
        end)

        -- If expanded, show content and adjust yPos
        if expanded and isEnabled then
            content:Show()
            yPos = yPos - contentHeight - 2
        end
    end


    -- ===== DIVIDER =====
    yPos = yPos - 4
    local div2 = parent:CreateTexture(nil, "ARTWORK")
    div2:SetPoint("TOPLEFT", 10, yPos)
    div2:SetSize(238, 1)
    div2:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 12

    -- ===== PRIORITY SLIDER (after type sections) =====
    local auraProxy = CreateAuraProxy(auraName)
    if not auraCfg or auraCfg.priority == nil then
        EnsureAuraConfig(auraName)
    end

    local priority = GUI:CreateSlider(parent, "Priority", 1, 10, 1, auraProxy, "priority")
    priority:SetPoint("TOPLEFT", 5, yPos)
    priority:SetWidth(contentWidth - 10)
    yPos = yPos - 58

    -- ===== DIVIDER =====
    local div3 = parent:CreateTexture(nil, "ARTWORK")
    div3:SetPoint("TOPLEFT", 10, yPos)
    div3:SetSize(238, 1)
    div3:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 12

    -- ===== EXPIRING INDICATOR SECTION (Collapsible Accordion) =====
    local c = GetThemeColor()
    local expCollapsed = true  -- Start collapsed

    -- Accordion header button
    local expHeader = CreateFrame("Button", nil, parent, "BackdropTemplate")
    expHeader:SetHeight(22)
    expHeader:SetPoint("TOPLEFT", 0, yPos)
    expHeader:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    ApplyBackdrop(expHeader, {r = C_ELEMENT.r * 0.8, g = C_ELEMENT.g * 0.8, b = C_ELEMENT.b * 0.8, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

    local expChevron = expHeader:CreateFontString(nil, "OVERLAY")
    expChevron:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    expChevron:SetPoint("LEFT", 10, 0)
    expChevron:SetText("\226\150\182")  -- ▶ right-pointing triangle (collapsed)
    expChevron:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local expTitleText = expHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    expTitleText:SetPoint("LEFT", expChevron, "RIGHT", 6, 0)
    expTitleText:SetText("Expiring Indicator")
    expTitleText:SetTextColor(c.r, c.g, c.b)

    expHeader:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    expHeader:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r * 0.8, C_ELEMENT.g * 0.8, C_ELEMENT.b * 0.8, 1)
    end)
    yPos = yPos - 24

    -- Container for all expiring controls
    local expBody = CreateFrame("Frame", nil, parent)
    expBody:SetPoint("TOPLEFT", 0, yPos)
    expBody:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    expBody:Hide()  -- Start collapsed

    local expYPos = 0
    local expProxy = CreateExpiringProxy(auraName)

    local expEnabled = GUI:CreateCheckbox(expBody, "Enable Expiring Effects", expProxy, "enabled")
    expEnabled:SetPoint("TOPLEFT", 5, expYPos)
    expYPos = expYPos - 28

    local expThreshold = GUI:CreateSlider(expBody, "Threshold (%)", 1, 100, 1, expProxy, "threshold")
    expThreshold:SetPoint("TOPLEFT", 5, expYPos)
    expThreshold:SetWidth(contentWidth - 10)
    expYPos = expYPos - 54

    local expBorder = GUI:CreateCheckbox(expBody, "Border on Expiring", expProxy, "borderEnabled")
    expBorder:SetPoint("TOPLEFT", 5, expYPos)
    expYPos = expYPos - 28

    local expBorderThickness = GUI:CreateSlider(expBody, "Border Thickness", 1, 5, 1, expProxy, "borderThickness")
    expBorderThickness:SetPoint("TOPLEFT", 5, expYPos)
    expBorderThickness:SetWidth(contentWidth - 10)
    expYPos = expYPos - 54

    local expBorderColor = GUI:CreateColorPicker(expBody, "Expiring Border Color", expProxy, "borderColor", true)
    expBorderColor:SetPoint("TOPLEFT", 5, expYPos)
    expBorderColor:SetWidth(contentWidth - 10)
    expYPos = expYPos - 28

    local expPulsate = GUI:CreateCheckbox(expBody, "Pulsate on Expiring", expProxy, "pulsate")
    expPulsate:SetPoint("TOPLEFT", 5, expYPos)
    expYPos = expYPos - 28

    local expTint = GUI:CreateCheckbox(expBody, "Tint on Expiring", expProxy, "tintEnabled")
    expTint:SetPoint("TOPLEFT", 5, expYPos)
    expYPos = expYPos - 28

    local expTintColor = GUI:CreateColorPicker(expBody, "Expiring Tint Color", expProxy, "tintColor", true)
    expTintColor:SetPoint("TOPLEFT", 5, expYPos)
    expTintColor:SetWidth(contentWidth - 10)
    expYPos = expYPos - 34

    local EXP_BODY_HEIGHT = -expYPos
    expBody:SetHeight(EXP_BODY_HEIGHT)

    -- Toggle accordion
    local function UpdateExpCollapse()
        if expCollapsed then
            expBody:Hide()
            expChevron:SetText("\226\150\182")  -- ▶
            parent:SetHeight(-yPos + 10)
        else
            expBody:Show()
            expChevron:SetText("\226\150\188")  -- ▼
            parent:SetHeight(-(yPos - EXP_BODY_HEIGHT) + 10)
        end
    end

    expHeader:SetScript("OnClick", function()
        expCollapsed = not expCollapsed
        UpdateExpCollapse()
    end)

    UpdateExpCollapse()  -- Apply initial collapsed state
end

local function RefreshRightPanel()
    for _, child in ipairs(rightPanelChildren) do
        child:Hide()
        child:SetParent(nil)
    end
    wipe(rightPanelChildren)

    if not rightScrollChild then return end

    -- ========================================
    -- Update right panel header
    -- ========================================
    if rightPanel and rightPanel.selHeader then
        if selectedAura == nil then
            -- Global view header
            rightPanel.selIcon:SetColorTexture(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            rightPanel.selName:SetText("Global Defaults")
            local tc = GetThemeColor()
            rightPanel.selName:SetTextColor(tc.r, tc.g, tc.b)
            rightPanel.selSub:SetText("Default values for all auras")
        else
            -- Per-aura header
            local spec = ResolveSpec()
            local auraInfo
            if spec then
                for _, info in ipairs(Adapter:GetTrackableAuras(spec)) do
                    if info.name == selectedAura then
                        auraInfo = info
                        break
                    end
                end
            end
            if auraInfo then
                local selIconTex = GetAuraIcon(spec, selectedAura)
                if selIconTex then
                    rightPanel.selIcon:SetTexture(selIconTex)
                    rightPanel.selIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                else
                    rightPanel.selIcon:SetTexCoord(0, 1, 0, 1)
                    rightPanel.selIcon:SetColorTexture(auraInfo.color[1] * 0.4, auraInfo.color[2] * 0.4, auraInfo.color[3] * 0.4, 1)
                end
                rightPanel.selName:SetText(auraInfo.display)
                rightPanel.selName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                local effectCount = CountActiveEffects(selectedAura)
                if effectCount > 0 then
                    rightPanel.selSub:SetText(effectCount .. " effect(s) configured")
                    rightPanel.selSub:SetTextColor(auraInfo.color[1], auraInfo.color[2], auraInfo.color[3])
                else
                    rightPanel.selSub:SetText("Not configured")
                    rightPanel.selSub:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                end
            else
                rightPanel.selIcon:SetColorTexture(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
                rightPanel.selName:SetText(selectedAura)
                rightPanel.selName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                rightPanel.selSub:SetText("")
            end
        end
    end

    -- ========================================
    -- Show/hide copy row and adjust scroll position
    -- ========================================
    if rightPanel.copyRow then
        if selectedAura ~= nil then
            rightPanel.copyRow:Show()
            rightPanel.copySourceAura = nil
            rightPanel.copyDropdownText:SetText("Select aura...")
            rightPanel.copyDropdownText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            rightScrollFrame:SetPoint("TOPLEFT", 0, -88)  -- 22 title + 40 header + 26 copy row
        else
            rightPanel.copyRow:Hide()
            rightScrollFrame:SetPoint("TOPLEFT", 0, -62)  -- 22 title + 40 header
        end
    end

    -- ========================================
    -- Build right panel content
    -- ========================================
    local container = CreateFrame("Frame", nil, rightScrollChild)
    container:SetPoint("TOPLEFT", 0, 0)
    container:SetPoint("TOPRIGHT", 0, 0)
    container:SetHeight(800)
    rightPanelChildren[#rightPanelChildren + 1] = container

    if selectedAura == nil then
        BuildGlobalView(container)
    else
        BuildPerAuraView(container, selectedAura)
    end

    -- Update scroll child height to match content
    local containerH = container:GetHeight()
    rightScrollChild:SetHeight(containerH)
end

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
        GetAuraDesignerDB().enabled = checked
        DF:AuraDesigner_RefreshPage()
    end)

    local cbLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 8, 2)
    cbLabel:SetText("Enable Aura Designer")
    cbLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local cbSubLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbSubLabel:SetPoint("TOPLEFT", cbLabel, "BOTTOMLEFT", 0, -1)
    cbSubLabel:SetText("(replaces Buffs tab)")
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
    specMenu:SetFrameStrata("DIALOG")
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
                selectedAura = nil
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
    return banner
end

-- ============================================================
-- ATTRIBUTION ROW
-- ============================================================

local function CreateAttributionRow(parent, yOffset)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(20)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)

    local available = Adapter:IsAvailable()

    -- Circle icon (H for Harrek)
    local icon = CreateFrame("Frame", nil, row, "BackdropTemplate")
    icon:SetPoint("LEFT", 4, 0)
    icon:SetSize(16, 16)
    ApplyBackdrop(icon, {r = 0.15, g = 0.15, b = 0.15, a = 1}, {r = 0.35, g = 0.35, b = 0.35, a = 1})

    local iconLetter = icon:CreateFontString(nil, "OVERLAY")
    iconLetter:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    iconLetter:SetPoint("CENTER", 0, 0)
    iconLetter:SetText("H")

    if available then
        iconLetter:SetTextColor(0.3, 0.8, 0.3)
        local poweredLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        poweredLabel:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        poweredLabel:SetText("Powered by")
        poweredLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        local nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameLabel:SetPoint("LEFT", poweredLabel, "RIGHT", 4, 0)
        nameLabel:SetText("Advanced Raid Frames")
        local tc = GetThemeColor()
        nameLabel:SetTextColor(tc.r, tc.g, tc.b)
    else
        iconLetter:SetTextColor(0.8, 0.3, 0.3)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        label:SetText("Harrek's Advanced Raid Frames not detected")
        label:SetTextColor(0.8, 0.6, 0.3, 1)
    end

    return row
end

-- ============================================================
-- STRIP HEADER HELPER
-- Creates a small header bar (TRACKABLE AURAS, ACTIVE EFFECTS, etc.)
-- ============================================================

local function CreateStripHeader(parent, text, accentColor)
    local header = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    header:SetHeight(18)
    ApplyBackdrop(header, C_BACKGROUND, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    local label = header:CreateFontString(nil, "OVERLAY")
    label:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    label:SetPoint("LEFT", 10, 0)
    label:SetText(text)
    if accentColor then
        label:SetTextColor(accentColor.r, accentColor.g, accentColor.b)
    else
        label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end

    -- Right-side count
    local countLabel = header:CreateFontString(nil, "OVERLAY")
    countLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    countLabel:SetPoint("RIGHT", -10, 0)
    countLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    header.countLabel = countLabel

    header.label = label
    return header
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

    -- Outer container with label
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetHeight(max(FRAME_H + 60, 130))  -- room for label + frame + instructions
    local rightInset = rightPanelRef and (rightPanelRef:GetWidth() + 6) or 290
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -rightInset, yOffset)
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
    container.borderOverlay = CreateFrame("Frame", nil, mockFrame, "BackdropTemplate")
    container.borderOverlay:SetAllPoints()
    container.borderOverlay:SetFrameLevel(mockFrame:GetFrameLevel() + 5)
    container.borderOverlay:Hide()

    -- Click background to deselect aura (return to Global view)
    local bgClick = CreateFrame("Button", nil, mockFrame)
    bgClick:SetAllPoints()
    bgClick:SetFrameLevel(mockFrame:GetFrameLevel() + 1)  -- Below dots and indicators
    bgClick:RegisterForClicks("LeftButtonUp")
    bgClick:SetScript("OnClick", function()
        if selectedAura then
            selectedAura = nil
            DF:AuraDesigner_RefreshPage()
        end
    end)

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
        anchorDots[anchorName] = dotFrame
    end

    -- Instructions with keyboard badge styling
    local instrRows = {
        { key = "Click",       desc = "an aura tile to configure its display settings" },
        { key = "Drag",        desc = "an aura tile onto the frame to place at a specific anchor" },
        { key = "Right-click", desc = "a placed indicator to remove it from the frame" },
    }

    local instrCount = #instrRows
    for i, row in ipairs(instrRows) do
        local rowBottomOffset = 4 + (instrCount - i) * 14

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

        -- Description text
        local descText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        descText:SetPoint("LEFT", badge, "RIGHT", 5, 0)
        descText:SetText(row.desc)
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
    end

    -- Adjust container height to accommodate instructions
    container:SetHeight(max(FRAME_H + 60 + #instrRows * 14, 130 + #instrRows * 14))

    -- Drag-state hint text (shows contextual guidance during drag operations)
    dragHintText = container:CreateFontString(nil, "OVERLAY")
    dragHintText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    dragHintText:SetPoint("TOP", mockFrame, "BOTTOM", 0, -6)
    dragHintText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    dragHintText:SetText("")

    return container
end

-- ============================================================
-- ACTIVE EFFECTS STRIP
-- With header bar and horizontal scroll for effect entries
-- ============================================================

local function CreateActiveEffectsStrip(parent, yOffset, rightPanelRef)
    local rightInset = rightPanelRef and (rightPanelRef:GetWidth() + 6) or 290
    local wrapper = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    wrapper:SetHeight(104)  -- 18 header + 82 strip + 4 padding
    wrapper:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    wrapper:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -rightInset, yOffset)
    ApplyBackdrop(wrapper, {r = 0.12, g = 0.12, b = 0.12, a = 1}, C_BORDER)

    -- Header
    local tc = GetThemeColor()
    local header = CreateStripHeader(wrapper, "ACTIVE EFFECTS", tc)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    wrapper.header = header

    -- Strip scroll area
    local stripScroll = CreateFrame("ScrollFrame", nil, wrapper)
    stripScroll:SetPoint("TOPLEFT", 0, -18)
    stripScroll:SetPoint("BOTTOMRIGHT", 0, 0)
    stripScroll:EnableMouseWheel(true)

    local stripContent = CreateFrame("Frame", nil, stripScroll)
    stripContent:SetHeight(82)
    stripContent:SetWidth(800)
    stripScroll:SetScrollChild(stripContent)

    stripScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetHorizontalScroll()
        local maxScrollVal = max(0, stripContent:GetWidth() - self:GetWidth())
        local newScroll = max(0, min(maxScrollVal, current - (delta * 68)))
        self:SetHorizontalScroll(newScroll)
    end)

    wrapper.stripContent = stripContent

    -- Placeholder text
    wrapper.placeholder = wrapper:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    wrapper.placeholder:SetPoint("CENTER", stripScroll, "CENTER", 0, 0)
    wrapper.placeholder:SetText("Enable effects on an aura to see them here")
    wrapper.placeholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)

    return wrapper
end

-- ============================================================
-- ACTIVE EFFECTS STRIP REFRESH
-- ============================================================
local activeEffectEntries = {}

local function RefreshActiveEffectsStrip()
    if not activeEffectsStrip then return end

    -- Clear old entries
    for _, entry in ipairs(activeEffectEntries) do
        entry:Hide()
    end
    wipe(activeEffectEntries)

    local adDB = GetAuraDesignerDB()
    local spec = ResolveSpec()
    if not spec then return end

    local auraList = Adapter:GetTrackableAuras(spec)
    if not auraList then return end

    -- Build a lookup for aura info
    local auraInfoLookup = {}
    for _, info in ipairs(auraList) do
        auraInfoLookup[info.name] = info
    end

    -- Collect all active effects
    local effects = {}
    for auraName, auraCfg in pairs(adDB.auras) do
        local info = auraInfoLookup[auraName]
        if info then
            for _, typeDef in ipairs(INDICATOR_TYPES) do
                if auraCfg[typeDef.key] then
                    tinsert(effects, {
                        auraName = auraName,
                        display = info.display,
                        color = info.color,
                        typeKey = typeDef.key,
                        typeLabel = typeDef.label,
                    })
                end
            end
        end
    end

    if #effects == 0 then
        activeEffectsStrip.placeholder:Show()
        return
    end
    activeEffectsStrip.placeholder:Hide()

    local stripParent = activeEffectsStrip.stripContent or activeEffectsStrip
    local xOffset = 10
    for _, effect in ipairs(effects) do
        local entry = CreateFrame("Button", nil, stripParent, "BackdropTemplate")
        entry:SetSize(68, 74)
        entry:SetPoint("LEFT", stripParent, "LEFT", xOffset, 0)
        local isSelected = (effect.auraName == selectedAura)
        if isSelected then
            local tc = GetThemeColor()
            ApplyBackdrop(entry, {r = tc.r * 0.12, g = tc.g * 0.12, b = tc.b * 0.12, a = 1}, {r = tc.r * 0.4, g = tc.g * 0.4, b = tc.b * 0.4, a = 0.6})
        else
            ApplyBackdrop(entry, {r = 0, g = 0, b = 0, a = 0}, {r = 0, g = 0, b = 0, a = 0})
        end

        -- X button to disable (circular with danger hover)
        local xBtn = CreateFrame("Button", nil, entry, "BackdropTemplate")
        xBtn:SetSize(14, 14)
        xBtn:SetPoint("TOPRIGHT", -1, -1)
        xBtn:SetFrameLevel(entry:GetFrameLevel() + 5)
        ApplyBackdrop(xBtn, {r = 0, g = 0, b = 0, a = 0}, {r = 0, g = 0, b = 0, a = 0})
        local xText = xBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        xText:SetPoint("CENTER", 0, 0)
        xText:SetText("\195\151")  -- × multiplication sign
        xText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        xBtn:SetScript("OnEnter", function(self)
            xText:SetTextColor(0.9, 0.25, 0.25)
            self:SetBackdropColor(0.8, 0.27, 0.27, 0.2)
            self:SetBackdropBorderColor(0.8, 0.27, 0.27, 0.4)
        end)
        xBtn:SetScript("OnLeave", function(self)
            xText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            self:SetBackdropColor(0, 0, 0, 0)
            self:SetBackdropBorderColor(0, 0, 0, 0)
        end)
        xBtn:SetScript("OnClick", function()
            local cfg = adDB.auras[effect.auraName]
            if cfg then
                cfg[effect.typeKey] = nil
                DF:AuraDesigner_RefreshPage()
            end
        end)

        -- Spell name
        local name = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("TOP", 0, -3)
        name:SetWidth(60)
        name:SetMaxLines(1)
        name:SetText(effect.display)
        name:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        name:SetJustifyH("CENTER")

        -- Icon with accent border
        local iconFrame = CreateFrame("Frame", nil, entry, "BackdropTemplate")
        iconFrame:SetSize(36, 36)
        iconFrame:SetPoint("CENTER", 0, 2)
        if not iconFrame.SetBackdrop then Mixin(iconFrame, BackdropTemplateMixin) end
        iconFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })
        iconFrame:SetBackdropColor(effect.color[1] * 0.25, effect.color[2] * 0.25, effect.color[3] * 0.25, 1)
        local tc = GetThemeColor()
        iconFrame:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)

        -- Spell icon or letter fallback
        local spec = ResolveSpec()
        local effIconTex = GetAuraIcon(spec, effect.auraName)

        local effIcon = iconFrame:CreateTexture(nil, "ARTWORK")
        effIcon:SetPoint("TOPLEFT", 2, -2)
        effIcon:SetPoint("BOTTOMRIGHT", -2, 2)
        if effIconTex then
            effIcon:SetTexture(effIconTex)
            effIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else
            effIcon:SetColorTexture(effect.color[1] * 0.3, effect.color[2] * 0.3, effect.color[3] * 0.3, 1)
        end

        local letter = iconFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        letter:SetPoint("CENTER", 0, 0)
        letter:SetText(effect.display:sub(1, 1))
        letter:SetTextColor(effect.color[1], effect.color[2], effect.color[3])
        if effIconTex then letter:Hide() end

        -- Type label (uppercase accent text)
        local typeLabel = entry:CreateFontString(nil, "OVERLAY")
        typeLabel:SetFont("Fonts\\FRIZQT__.TTF", 7, "OUTLINE")
        typeLabel:SetPoint("BOTTOM", 0, 3)
        typeLabel:SetWidth(64)
        typeLabel:SetMaxLines(1)
        typeLabel:SetText(effect.typeLabel:upper())
        typeLabel:SetTextColor(tc.r, tc.g, tc.b)

        -- Click to select aura
        entry:SetScript("OnClick", function()
            selectedAura = effect.auraName
            DF:AuraDesigner_RefreshPage()
        end)
        entry:SetScript("OnEnter", function(self)
            if not isSelected then
                self:SetBackdropColor(1, 1, 1, 0.03)
            end
        end)
        entry:SetScript("OnLeave", function(self)
            if not isSelected then
                self:SetBackdropColor(0, 0, 0, 0)
            end
        end)

        tinsert(activeEffectEntries, entry)
        xOffset = xOffset + 74
    end

    -- Update scroll content width
    if stripParent.SetWidth then
        stripParent:SetWidth(max(xOffset + 10, 100))
    end

    -- Update header count
    if activeEffectsStrip.header and activeEffectsStrip.header.label then
        activeEffectsStrip.header.label:SetText("ACTIVE EFFECTS (" .. #effects .. ")")
    end
end

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildAuraDesignerPage(guiRef, pageRef, dbRef)
    GUI = guiRef
    page = pageRef
    db = dbRef
    Adapter = DF.AuraDesigner.Adapter

    local parent = page.child

    -- ========================================
    -- CLEANUP: Hide frames from any previous build
    -- When the page is rebuilt (e.g., window resize), old frames
    -- would stay visible underneath new ones without this.
    -- ========================================
    if mainFrame then
        mainFrame:Hide()
        mainFrame:SetParent(nil)
    end
    -- Clear placed indicator references (they were children of the old preview)
    wipe(placedIndicators)
    -- Clear right panel children (they were children of the old scroll child)
    wipe(rightPanelChildren)

    -- Layout constants
    local BANNER_H = 36
    local ATTRIB_H = 20
    local TILE_HEADER_H = 18
    local TILE_STRIP_H = 82   -- inner scroll area
    local SECTION_GAP = 8
    local RIGHT_PANEL_W = 280
    local RIGHT_GAP = 6       -- gap between left content and right panel

    -- ========================================
    -- MAIN FRAME
    -- ========================================
    mainFrame = CreateFrame("Frame", nil, parent)
    mainFrame:SetAllPoints()

    -- Override RefreshStates: Aura Designer uses its own layout system, not the
    -- standard widget-based one. The default RefreshStates would calculate maxY = 0
    -- (no standard widgets) and set page.child:SetHeight(~40), which makes mainFrame
    -- (via SetAllPoints) too short. This causes rightPanel and rightScrollFrame to
    -- have zero effective height since their BOTTOMRIGHT anchors to mainFrame's bottom.
    page.RefreshStates = function(self)
        -- Set scroll child height to match the visible page area so mainFrame fills it
        local pageH = self:GetHeight()
        self.child:SetHeight(math.max(pageH, 600))
        -- Keep scroll child width in sync with content area
        if self.child and GUI.contentFrame then
            self.child:SetWidth(GUI.contentFrame:GetWidth() - 30)
        end
    end

    local yPos = 0

    -- ========================================
    -- ENABLE BANNER (full width)
    -- ========================================
    enableBanner = CreateEnableBanner(mainFrame)
    enableBanner:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    enableBanner:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, yPos)
    enableBanner.UpdateSpecText()
    yPos = yPos - (BANNER_H + 4)

    -- ========================================
    -- ATTRIBUTION ROW (full width)
    -- ========================================
    attributionRow = CreateAttributionRow(mainFrame, yPos)
    yPos = yPos - (ATTRIB_H + 4)

    -- ========================================
    -- RIGHT PANEL (fixed 280px, starts here)
    -- Built BEFORE left content so left content can anchor to it
    -- ========================================
    rightPanel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    rightPanel:SetWidth(RIGHT_PANEL_W)
    rightPanel:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, yPos)
    rightPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    ApplyBackdrop(rightPanel, {r = 0.10, g = 0.10, b = 0.10, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    -- Right panel "SETTINGS" title bar
    rightPanel.titleBar = CreateFrame("Frame", nil, rightPanel, "BackdropTemplate")
    rightPanel.titleBar:SetHeight(22)
    rightPanel.titleBar:SetPoint("TOPLEFT", 0, 0)
    rightPanel.titleBar:SetPoint("TOPRIGHT", 0, 0)
    ApplyBackdrop(rightPanel.titleBar, {r = 0.09, g = 0.09, b = 0.09, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    local settingsTitle = rightPanel.titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    settingsTitle:SetPoint("LEFT", 10, 0)
    settingsTitle:SetText("SETTINGS")
    settingsTitle:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Right panel selected-aura header
    rightPanel.selHeader = CreateFrame("Frame", nil, rightPanel, "BackdropTemplate")
    rightPanel.selHeader:SetHeight(40)
    rightPanel.selHeader:SetPoint("TOPLEFT", rightPanel.titleBar, "BOTTOMLEFT", 0, 0)
    rightPanel.selHeader:SetPoint("TOPRIGHT", rightPanel.titleBar, "BOTTOMRIGHT", 0, 0)
    ApplyBackdrop(rightPanel.selHeader, C_BACKGROUND, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    rightPanel.selIconFrame = CreateFrame("Frame", nil, rightPanel.selHeader, "BackdropTemplate")
    rightPanel.selIconFrame:SetSize(30, 30)
    rightPanel.selIconFrame:SetPoint("LEFT", 10, 0)
    ApplyBackdrop(rightPanel.selIconFrame, {r = 0, g = 0, b = 0, a = 0.3}, C_BORDER)

    rightPanel.selIcon = rightPanel.selIconFrame:CreateTexture(nil, "ARTWORK")
    rightPanel.selIcon:SetPoint("TOPLEFT", 1, -1)
    rightPanel.selIcon:SetPoint("BOTTOMRIGHT", -1, 1)

    rightPanel.selName = rightPanel.selHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rightPanel.selName:SetPoint("TOPLEFT", rightPanel.selIconFrame, "TOPRIGHT", 8, -2)
    rightPanel.selName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    rightPanel.selSub = rightPanel.selHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rightPanel.selSub:SetPoint("TOPLEFT", rightPanel.selName, "BOTTOMLEFT", 0, -1)
    rightPanel.selSub:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Copy-from row (visible only in per-aura view)
    rightPanel.copyRow = CreateFrame("Frame", nil, rightPanel, "BackdropTemplate")
    rightPanel.copyRow:SetHeight(26)
    rightPanel.copyRow:SetPoint("TOPLEFT", rightPanel.selHeader, "BOTTOMLEFT", 0, 0)
    rightPanel.copyRow:SetPoint("TOPRIGHT", rightPanel.selHeader, "BOTTOMRIGHT", 0, 0)
    -- Accent-tinted background (matches mockup rgba(115,115,242,.04) over panel)
    local ctc = GetThemeColor()
    ApplyBackdrop(rightPanel.copyRow, {r = C_PANEL.r + ctc.r * 0.04, g = C_PANEL.g + ctc.g * 0.04, b = C_PANEL.b + ctc.b * 0.04, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})
    rightPanel.copyRow:Hide()

    local copyLabel = rightPanel.copyRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyLabel:SetPoint("LEFT", 10, 0)
    copyLabel:SetText("Copy from:")
    copyLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Dropdown (simple button that opens a menu)
    rightPanel.copyDropdown = CreateFrame("Frame", nil, rightPanel.copyRow, "BackdropTemplate")
    rightPanel.copyDropdown:SetHeight(18)
    rightPanel.copyDropdown:SetPoint("LEFT", copyLabel, "RIGHT", 6, 0)
    rightPanel.copyDropdown:SetPoint("RIGHT", rightPanel.copyRow, "RIGHT", -60, 0)
    ApplyBackdrop(rightPanel.copyDropdown, C_ELEMENT, C_BORDER)

    rightPanel.copyDropdownText = rightPanel.copyDropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rightPanel.copyDropdownText:SetPoint("LEFT", 5, 0)
    rightPanel.copyDropdownText:SetPoint("RIGHT", -14, 0)
    rightPanel.copyDropdownText:SetJustifyH("LEFT")
    rightPanel.copyDropdownText:SetText("Select aura...")
    rightPanel.copyDropdownText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local copyArrow = rightPanel.copyDropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyArrow:SetPoint("RIGHT", -3, 0)
    copyArrow:SetText("\226\150\188") -- small down triangle
    copyArrow:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Copy button
    rightPanel.copyBtn = CreateFrame("Button", nil, rightPanel.copyRow, "BackdropTemplate")
    rightPanel.copyBtn:SetSize(46, 18)
    rightPanel.copyBtn:SetPoint("RIGHT", rightPanel.copyRow, "RIGHT", -8, 0)
    local tc = GetThemeColor()
    ApplyBackdrop(rightPanel.copyBtn, C_ELEMENT, {r = tc.r, g = tc.g, b = tc.b, a = 0.8})

    local copyBtnText = rightPanel.copyBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyBtnText:SetPoint("CENTER", 0, 0)
    copyBtnText:SetText("Copy")
    copyBtnText:SetTextColor(tc.r, tc.g, tc.b)

    rightPanel.copyBtn:SetScript("OnEnter", function(self)
        local c = GetThemeColor()
        self:SetBackdropColor(c.r, c.g, c.b, 0.3)
    end)
    rightPanel.copyBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)

    -- State for copy-from selection
    rightPanel.copySourceAura = nil

    -- Custom popup menu frame (reusable, addon-styled)
    local copyMenuFrame = CreateFrame("Frame", nil, rightPanel.copyDropdown, "BackdropTemplate")
    copyMenuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    copyMenuFrame:SetClampedToScreen(true)
    ApplyBackdrop(copyMenuFrame, C_PANEL, C_BORDER)
    copyMenuFrame:Hide()
    local copyMenuButtons = {}

    -- Dropdown click: show menu of other auras for the current spec
    local copyDropdownBtn = CreateFrame("Button", nil, rightPanel.copyDropdown)
    copyDropdownBtn:SetAllPoints()
    copyDropdownBtn:SetScript("OnClick", function(self)
        if copyMenuFrame:IsShown() then
            copyMenuFrame:Hide()
            return
        end

        local spec = ResolveSpec()
        if not spec then return end
        local auraList = Adapter:GetTrackableAuras(spec)
        if not auraList then return end

        -- Clear old buttons
        for _, btn in ipairs(copyMenuButtons) do
            btn:Hide()
            btn:SetParent(nil)
        end
        wipe(copyMenuButtons)

        -- Build menu items
        local idx = 0
        for _, info in ipairs(auraList) do
            if info.name ~= selectedAura then
                local menuBtn = CreateFrame("Button", nil, copyMenuFrame)
                menuBtn:SetPoint("TOPLEFT", 2, -2 - idx * 20)
                menuBtn:SetPoint("TOPRIGHT", -2, -2 - idx * 20)
                menuBtn:SetHeight(20)

                local btnText = menuBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btnText:SetPoint("LEFT", 8, 0)
                btnText:SetText(info.display)
                btnText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                local hl = menuBtn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                local c = GetThemeColor()
                hl:SetColorTexture(c.r, c.g, c.b, 0.3)

                local capturedName = info.name
                local capturedDisplay = info.display
                menuBtn:SetScript("OnClick", function()
                    rightPanel.copySourceAura = capturedName
                    rightPanel.copyDropdownText:SetText(capturedDisplay)
                    rightPanel.copyDropdownText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                    copyMenuFrame:Hide()
                end)

                tinsert(copyMenuButtons, menuBtn)
                idx = idx + 1
            end
        end

        if idx == 0 then return end

        copyMenuFrame:SetPoint("TOPLEFT", rightPanel.copyDropdown, "BOTTOMLEFT", 0, -2)
        copyMenuFrame:SetPoint("TOPRIGHT", rightPanel.copyDropdown, "BOTTOMRIGHT", 0, -2)
        copyMenuFrame:SetHeight(idx * 20 + 4)
        copyMenuFrame:Show()
    end)

    -- Close menu when clicking elsewhere
    copyMenuFrame:SetScript("OnShow", function()
        copyMenuFrame:SetPropagateKeyboardInput(true)
    end)
    copyMenuFrame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- Copy button click: copy all settings from source to current aura
    rightPanel.copyBtn:SetScript("OnClick", function()
        if not rightPanel.copySourceAura or not selectedAura then return end
        local adDB = GetAuraDesignerDB()
        local sourceCfg = adDB.auras[rightPanel.copySourceAura]
        if not sourceCfg then return end

        -- Deep copy
        local function deepCopy(tbl)
            local copy = {}
            for k, v in pairs(tbl) do
                if type(v) == "table" then
                    copy[k] = deepCopy(v)
                else
                    copy[k] = v
                end
            end
            return copy
        end

        adDB.auras[selectedAura] = deepCopy(sourceCfg)
        DF:AuraDesigner_RefreshPage()
    end)

    -- Scroll frame below header (and copy row when visible)
    -- Default offset: 22 title + 40 header = 62
    rightScrollFrame = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    rightScrollFrame:SetPoint("TOPLEFT", 0, -62)
    rightScrollFrame:SetPoint("BOTTOMRIGHT", -22, 0)

    rightScrollChild = CreateFrame("Frame", nil, rightScrollFrame)
    rightScrollChild:SetWidth(258)
    rightScrollChild:SetHeight(800)
    rightScrollFrame:SetScrollChild(rightScrollChild)

    local scrollBar = rightScrollFrame.ScrollBar
    if scrollBar then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPLEFT", rightScrollFrame, "TOPRIGHT", 2, -16)
        scrollBar:SetPoint("BOTTOMLEFT", rightScrollFrame, "BOTTOMRIGHT", 2, 16)
    end

    -- Smooth scroll — override default scroll step for smaller increments
    local SCROLL_STEP = 30
    rightScrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = max(0, self:GetVerticalScrollRange())
        local newScroll = max(0, min(maxScroll, current - (delta * SCROLL_STEP)))
        self:SetVerticalScroll(newScroll)
    end)
    -- Also propagate mouse wheel from the scroll child
    rightScrollChild:EnableMouseWheel(true)
    rightScrollChild:SetScript("OnMouseWheel", function(self, delta)
        local parent = self:GetParent()
        if parent and parent:GetScript("OnMouseWheel") then
            parent:GetScript("OnMouseWheel")(parent, delta)
        end
    end)

    -- ========================================
    -- LEFT CONTENT: TILE STRIP
    -- All left content anchors TOPRIGHT to rightPanel's TOPLEFT
    -- ========================================
    local tileWrap = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    tileWrap:SetHeight(TILE_HEADER_H + TILE_STRIP_H)
    tileWrap:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    tileWrap:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -(RIGHT_PANEL_W + RIGHT_GAP), yPos)
    ApplyBackdrop(tileWrap, C_PANEL, C_BORDER)

    -- Header bar
    tileStripHeader = CreateStripHeader(tileWrap, "TRACKABLE AURAS")
    tileStripHeader:SetPoint("TOPLEFT", 0, 0)
    tileStripHeader:SetPoint("TOPRIGHT", 0, 0)

    -- Scroll area below header
    tileStrip = CreateFrame("ScrollFrame", nil, tileWrap)
    tileStrip:SetPoint("TOPLEFT", 0, -TILE_HEADER_H)
    tileStrip:SetPoint("BOTTOMRIGHT", 0, 0)
    tileStrip:EnableMouseWheel(true)

    tileStripContent = CreateFrame("Frame", nil, tileStrip)
    tileStripContent:SetHeight(TILE_STRIP_H)
    tileStripContent:SetWidth(800)
    tileStrip:SetScrollChild(tileStripContent)

    tileStrip:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetHorizontalScroll()
        local maxScroll = max(0, tileStripContent:GetWidth() - self:GetWidth())
        local newScroll = max(0, min(maxScroll, current - (delta * 68)))
        self:SetHorizontalScroll(newScroll)
    end)

    yPos = yPos - (TILE_HEADER_H + TILE_STRIP_H + SECTION_GAP)

    -- ========================================
    -- LEFT CONTENT: FRAME PREVIEW
    -- ========================================
    framePreview = CreateFramePreview(mainFrame, yPos, rightPanel)
    local previewH = framePreview:GetHeight()
    yPos = yPos - (previewH + SECTION_GAP)

    -- ========================================
    -- LEFT CONTENT: ACTIVE EFFECTS STRIP
    -- ========================================
    activeEffectsStrip = CreateActiveEffectsStrip(mainFrame, yPos, rightPanel)

    -- ========================================
    -- POPULATE
    -- ========================================
    PopulateTileStrip()
    RefreshRightPanel()
    RefreshActiveEffectsStrip()
    RefreshPlacedIndicators()
    RefreshPreviewEffects()
end

-- ============================================================
-- REFRESH
-- ============================================================

function DF:AuraDesigner_RefreshPage()
    if not mainFrame then return end

    -- Refresh tile states
    for _, tile in ipairs(activeTiles) do
        tile:SetSelected(selectedAura == tile.auraName)
        if tile.UpdateBadge then tile:UpdateBadge() end
    end

    -- Check if spec changed
    local currentSpec = ResolveSpec()
    if currentSpec ~= selectedSpec then
        selectedAura = nil
        PopulateTileStrip()
    end

    -- Refresh panels
    RefreshRightPanel()
    RefreshActiveEffectsStrip()
    RefreshPlacedIndicators()
    RefreshPreviewEffects()

    -- Update enable state
    if enableBanner then
        enableBanner.checkbox:SetChecked(GetAuraDesignerDB().enabled)
        enableBanner.UpdateSpecText()
    end

    -- Tab disable logic: strikethrough + 0.3 opacity when Aura Designer is enabled
    if GUI and GUI.Tabs then
        local adEnabled = GetAuraDesignerDB().enabled
        local disableTabs = { "auras_buffs", "auras_mybuffindicators" }
        for _, tabKey in ipairs(disableTabs) do
            local tab = GUI.Tabs[tabKey]
            if tab then
                tab.disabled = adEnabled
                if adEnabled then
                    tab:SetAlpha(0.3)
                    -- Add strikethrough if not already present
                    if not tab._strikethrough then
                        tab._strikethrough = tab:CreateTexture(nil, "OVERLAY")
                        tab._strikethrough:SetColorTexture(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
                        tab._strikethrough:SetHeight(1)
                        tab._strikethrough:SetPoint("LEFT", tab.Text or tab, "LEFT", 0, 0)
                        tab._strikethrough:SetPoint("RIGHT", tab.Text or tab, "RIGHT", 0, 0)
                    end
                    tab._strikethrough:Show()
                else
                    tab:SetAlpha(1)
                    if tab._strikethrough then
                        tab._strikethrough:Hide()
                    end
                end
            end
        end
    end
end
