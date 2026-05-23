local addonName, DF = ...

if DF.RELEASE_CHANNEL == "release" then return end

local L = DF.L

-- ============================================================
-- COLOR CONSTANTS & SHARED HELPERS
-- Mirrors AuraDesigner's palette so the Text Designer reads as the same
-- visual family as the rest of the addon.
-- ============================================================

local C_BACKGROUND = {r = 0.08, g = 0.08, b = 0.08, a = 0.95}
local C_PANEL      = {r = 0.12, g = 0.12, b = 0.12, a = 1}
local C_ELEMENT    = {r = 0.18, g = 0.18, b = 0.18, a = 1}
local C_BORDER     = {r = 0.25, g = 0.25, b = 0.25, a = 1}
local C_HOVER      = {r = 0.22, g = 0.22, b = 0.22, a = 1}
local C_TEXT       = {r = 0.9, g = 0.9, b = 0.9, a = 1}
local C_TEXT_DIM   = {r = 0.6, g = 0.6, b = 0.6, a = 1}
local C_PANEL_VISIBLE  = {r = 1, g = 1, b = 1, a = 0.05}
local C_BORDER_VISIBLE = {r = 1, g = 1, b = 1, a = 0.2}

local function ApplyBackdrop(frame, bg, border)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    if bg then
        frame:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1)
    end
    if border then
        frame:SetBackdropBorderColor(border.r, border.g, border.b, border.a or 1)
    end
end

-- ============================================================
-- TEXT DESIGNER - GUI BUILDER
-- Phase 1: non-functional UI scaffold. Adds tab-level controls
-- (master toggle, Add Element button) and the empty state.
-- Card list, picker, and per-card editor land in subsequent tasks.
-- ============================================================

local CreateFrame = CreateFrame
local pairs, ipairs = pairs, ipairs

-- ============================================================
-- CONTENT TYPE CATALOG
-- 23 types organized into 6 categories. Each entry:
--   { key = "internal_id", label = L["Display Name"], category = "Health" }
-- The picker (search + pills + grouped list) reads this table.
-- Phase 2 will add per-type renderers; Phase 1 just stores `contentType` on
-- each element instance.
-- ============================================================

local CONTENT_CATEGORIES = {
    "group", "identity", "health", "power", "shields", "status", "threat",
}

local CONTENT_CATEGORY_LABELS = {
    identity = L["Identity & Roster"],
    health   = L["Health"],
    power    = L["Power"],
    shields  = L["Shields & Heals"],
    status   = L["Status"],
    threat   = L["Threat & Range"],
    group    = L["Group"],
}

local CONTENT_TYPES = {
    -- Identity & Roster
    { key = "name",              label = L["Name"],                       category = "identity" },
    { key = "class",             label = L["Class"],                      category = "identity" },
    { key = "group_number",      label = L["Group Number"],               category = "identity" },
    { key = "race_level_faction",label = L["Race / Level / Faction"],     category = "identity" },
    { key = "custom_static",     label = L["Custom Static Text"],         category = "identity" },
    -- Health
    { key = "hp_current",        label = L["Current HP"],                 category = "health"   },
    { key = "hp_max",            label = L["Max HP"],                     category = "health"   },
    { key = "hp_percent",        label = L["HP Percent"],                 category = "health"   },
    { key = "hp_deficit",        label = L["HP Deficit"],                 category = "health"   },
    { key = "hp_max_reduction",  label = L["Max HP Reduction %"],         category = "health"   },
    -- Power
    { key = "power_current",     label = L["Current Power"],              category = "power"    },
    { key = "power_percent",     label = L["Power %"],                    category = "power"    },
    { key = "power_deficit",     label = L["Power Deficit"],              category = "power"    },
    { key = "power_type_string", label = L["Power Type String"],          category = "power"    },
    -- Shields & Heals
    { key = "absorb_amount",     label = L["Absorb Amount"],              category = "shields"  },
    { key = "overshield_amount", label = L["Overshield Amount"],          category = "shields"  },
    { key = "heal_absorb_amount",label = L["Heal Absorb Amount"],         category = "shields"  },
    { key = "incoming_heal",     label = L["Incoming Heal"],              category = "shields"  },
    { key = "incoming_heal_mine",label = L["Incoming Heal From Me Only"], category = "shields"  },
    -- Status
    { key = "status_text",       label = L["Dead / Offline / Ghost"],     category = "status"   },
    -- Threat & Range
    { key = "aggro_flag",        label = L["Aggro Flag"],                 category = "threat"   },
    { key = "threat_percent",    label = L["Threat %"],                   category = "threat"   },
    { key = "range_text",        label = L["In-Range / OOR Text"],        category = "threat"   },
    -- Group
    { key = "group",             label = L["Text Group"],                 category = "group"    },
}

local function FindContentType(key)
    for _, t in ipairs(CONTENT_TYPES) do
        if t.key == key then return t end
    end
end

-- ============================================================
-- BODY SECTION HELPERS
-- Shared layout primitives used by the Content / Appearance / Position
-- section builders.
-- ============================================================

local SECTION_LABEL_HEIGHT = 18
-- Y-decrement per field row. GUI helpers vary in height (CreateDropdown ~36,
-- CreateSlider ~30, CreateEditBox ~48 with label-above), so this value is
-- tuned to clear the tallest common widget without being wasteful. The
-- custom_static row uses an even taller decrement (see BuildContentSection)
-- because CreateEditBox renders its label above the input.
local FIELD_ROW_HEIGHT = 44
local SECTION_GAP = 8

local function CreateSectionLabel(GUI, parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(fs, 9, "OUTLINE")
    fs:SetText(text:upper())
    fs:SetTextColor(0.5, 0.7, 1, 0.9)
    return fs
end

-- Forward-declared so BuildContentSection's group branch can reference the
-- picker that's defined later in the file.
local BuildPicker

-- Returns the y-offset where the next section should start (negative, goes down).
-- tdDB / state / page are needed by the Text Group branch so its nested
-- add/remove callbacks can trigger a card-list re-render.
-- `card` is the parent settings group; the Label edit box updates card.title.
local function BuildContentSection(GUI, parent, elem, tdDB, state, page, card, yStart)
    local label = CreateSectionLabel(GUI, parent, L["Content"])
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yStart)
    local y = yStart - SECTION_LABEL_HEIGHT

    local ct = FindContentType(elem.contentType)
    if not ct then return y end

    -- ── Label (optional) ─────────────────────────────────────
    -- A user-friendly name for this element. Falls back to the content type
    -- name when empty. Used in the card header title and the Anchor To
    -- dropdown's options.
    elem.label = elem.label or ""
    local labelEdit = GUI:CreateEditBox(parent, L["Label (optional)"], elem, "label", function()
        if card and card.title then
            local activeCT = FindContentType(elem.contentType)
            local displayName = (elem.label and elem.label ~= "" and elem.label)
                or (activeCT and activeCT.label)
                or elem.contentType
            card.title:SetText(displayName)
        end
    end, 200)
    labelEdit:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    -- CreateEditBox is label-above style; row is taller than other widgets.
    y = y - 56

    -- Numeric types: abbreviate checkbox
    if ct.key == "hp_current" or ct.key == "hp_max" or ct.key == "hp_deficit"
       or ct.key == "power_current" or ct.key == "power_deficit"
       or ct.key == "absorb_amount" or ct.key == "overshield_amount"
       or ct.key == "heal_absorb_amount"
       or ct.key == "incoming_heal" or ct.key == "incoming_heal_mine"
    then
        elem.abbreviate = elem.abbreviate
        if elem.abbreviate == nil then elem.abbreviate = true end
        local abbrev = GUI:CreateCheckbox(parent, L["Abbreviate"], elem, "abbreviate", function() end)
        abbrev:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
        y = y - FIELD_ROW_HEIGHT

    -- Percent types: decimals slider
    elseif ct.key == "hp_percent" or ct.key == "power_percent"
           or ct.key == "hp_max_reduction" or ct.key == "threat_percent" then
        elem.decimals = elem.decimals or 0
        local dec = GUI:CreateSlider(parent, L["Decimal Places"], 0, 2, 1, elem, "decimals", function() end)
        dec:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
        y = y - FIELD_ROW_HEIGHT

    -- Name: length cap + truncate mode
    elseif ct.key == "name" then
        elem.nameLength = elem.nameLength or 12
        local lenSlider = GUI:CreateSlider(parent, L["Length"], 1, 30, 1, elem, "nameLength", function() end)
        lenSlider:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
        y = y - FIELD_ROW_HEIGHT

        elem.truncateMode = elem.truncateMode or "ELLIPSIS"
        local truncOpts = { ELLIPSIS = L["Ellipsis"], CUT = L["Cut"] }
        local truncDrop = GUI:CreateDropdown(parent, L["Truncate Mode"], truncOpts, elem, "truncateMode", function() end)
        truncDrop:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
        y = y - FIELD_ROW_HEIGHT

    -- Custom static text: a plain edit box
    elseif ct.key == "custom_static" then
        elem.staticText = elem.staticText or ""
        local edit = GUI:CreateEditBox(parent, L["Text"], elem, "staticText", function() end, 240)
        edit:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
        -- CreateEditBox renders its label ABOVE the input, so the row is
        -- taller than other widgets. Use a custom y-decrement instead of
        -- FIELD_ROW_HEIGHT.
        y = y - 56

    -- Group number: prefix/suffix format
    elseif ct.key == "group_number" then
        elem.groupFormat = elem.groupFormat or "SUFFIX"
        local opts = {
            PREFIX = L["Prefix"],
            SUFFIX = L["Suffix"],
            STANDALONE = L["Standalone"],
        }
        local fmtDrop = GUI:CreateDropdown(parent, L["Format"], opts, elem, "groupFormat", function() end)
        fmtDrop:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
        y = y - FIELD_ROW_HEIGHT

    -- Text Group: concatenates 2+ child content values with a user separator.
    -- Phase 1 stores groupItems / groupSeparator on the element; Phase 2 will
    -- wire the runtime renderer.
    elseif ct.key == "group" then
        elem.groupItems = elem.groupItems or {}
        elem.groupSeparator = elem.groupSeparator or " / "

        -- Helper to re-render the whole card list when items change.
        local function ReRender()
            if state and DF.TextDesigner.RenderCardList then
                DF.TextDesigner.RenderCardList(GUI, page, tdDB, state)
            end
        end

        -- Separator input (CreateEditBox renders its label ABOVE the input)
        local sepEdit = GUI:CreateEditBox(parent, L["Separator"], elem, "groupSeparator", function() end, 120)
        sepEdit:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
        y = y - 56

        -- Items label
        local itemsLabel = parent:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(itemsLabel, 9, "OUTLINE")
        itemsLabel:SetText(L["Items"]:upper())
        itemsLabel:SetTextColor(0.5, 0.7, 1, 0.9)
        itemsLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
        y = y - 16

        -- Items list — one row per item in elem.groupItems
        local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
        if #elem.groupItems == 0 then
            local emptyLbl = parent:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(emptyLbl, 10, "")
            emptyLbl:SetText(L["No items yet"])
            emptyLbl:SetTextColor(0.5, 0.5, 0.5)
            emptyLbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 26, y)
            y = y - 18
        else
            for itemIdx, itemKey in ipairs(elem.groupItems) do
                local itemCT = FindContentType(itemKey)
                local itemRow = CreateFrame("Frame", nil, parent)
                itemRow:SetHeight(20)
                itemRow:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y)
                itemRow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -22, y)

                local itemLabel = itemRow:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(itemLabel, 10, "")
                itemLabel:SetPoint("LEFT", itemRow, "LEFT", 4, 0)
                itemLabel:SetText(itemIdx .. ". " .. (itemCT and itemCT.label or itemKey))
                itemLabel:SetTextColor(0.9, 0.9, 0.9)

                -- Remove button
                local removeBtn = CreateFrame("Button", nil, itemRow)
                removeBtn:SetSize(16, 16)
                removeBtn:SetPoint("RIGHT", itemRow, "RIGHT", -4, 0)
                local removeIcon = removeBtn:CreateTexture(nil, "OVERLAY")
                removeIcon:SetAllPoints()
                removeIcon:SetTexture(mediaPath .. "delete")
                removeIcon:SetVertexColor(0.85, 0.4, 0.4)
                removeBtn:SetScript("OnEnter", function() removeIcon:SetVertexColor(1, 0.6, 0.6) end)
                removeBtn:SetScript("OnLeave", function() removeIcon:SetVertexColor(0.85, 0.4, 0.4) end)
                local capturedIdx = itemIdx
                removeBtn:SetScript("OnClick", function()
                    table.remove(elem.groupItems, capturedIdx)
                    ReRender()
                end)

                y = y - 22
            end
        end

        -- Add Item button — opens a picker that excludes the "group" type
        -- (no nested groups). The picker is cached on the card so repeated
        -- clicks reuse the same frame instead of spawning new offscreen ones.
        local addItemBtn
        addItemBtn = GUI:CreateButton(parent, "+ " .. L["Add Item"], 100, 22, function()
            if not BuildPicker then return end
            if card and not card._addItemPicker then
                card._addItemPicker = BuildPicker(GUI, parent, tdDB, function(typeKey)
                    table.insert(elem.groupItems, typeKey)
                    ReRender()
                end, "group")
            end
            local picker = card and card._addItemPicker
            if not picker then return end
            if picker:IsShown() then
                picker:Hide()
            else
                -- Anchor left-aligned: the Add Item button sits on the LEFT
                -- of the card body, so the dropdown extends RIGHT and DOWN.
                picker:Open(addItemBtn, "left")
            end
        end)
        addItemBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y)
        y = y - 32
    end
    -- Types with no Content-section fields fall through:
    -- class, status_text, aggro_flag, range_text, power_type_string, race_level_faction.
    -- They render only the section header (no fields), which is fine.

    return y - SECTION_GAP
end

-- ============================================================
-- 9-POINT ANCHOR GRID WIDGET
-- 3x3 grid of buttons mapping to TOPLEFT, TOP, TOPRIGHT, LEFT, CENTER, etc.
-- Click selects. Selected button is highlighted.
-- ============================================================

local ANCHOR_GRID = {
    {"TOPLEFT",    "TOP",      "TOPRIGHT"},
    {"LEFT",       "CENTER",   "RIGHT"},
    {"BOTTOMLEFT", "BOTTOM",   "BOTTOMRIGHT"},
}

local function CreateAnchorGrid(GUI, parent, elem)
    local grid = CreateFrame("Frame", nil, parent)
    grid:SetSize(60, 60)

    local btns = {}
    local function ApplyButtonState(b, active)
        if active then
            b:SetBackdropColor(0.3, 0.55, 0.9, 0.9)
            b:SetBackdropBorderColor(0.5, 0.75, 1, 1)
        else
            b:SetBackdropColor(0.12, 0.14, 0.18, 0.8)
            b:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.6)
        end
    end

    for row = 1, 3 do
        for col = 1, 3 do
            local point = ANCHOR_GRID[row][col]
            local b = CreateFrame("Button", nil, grid, "BackdropTemplate")
            b:SetSize(18, 18)
            b:SetPoint("TOPLEFT", grid, "TOPLEFT", (col - 1) * 20, -((row - 1) * 20))
            b:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            b.point = point
            btns[point] = b
            b:SetScript("OnClick", function()
                elem.anchor = point
                for p, bb in pairs(btns) do
                    ApplyButtonState(bb, p == point)
                end
            end)
        end
    end

    -- Initial state
    elem.anchor = elem.anchor or "CENTER"
    for p, b in pairs(btns) do
        ApplyButtonState(b, p == elem.anchor)
    end

    return grid
end

-- Returns the y-offset where the next section should start (negative, goes down).
-- `card` is accepted for signature consistency with BuildContentSection; not used.
local function BuildAppearanceSection(GUI, parent, elem, card, yStart)
    local label = CreateSectionLabel(GUI, parent, L["Appearance"])
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yStart)
    local y = yStart - SECTION_LABEL_HEIGHT

    -- Defaults
    elem.font = elem.font or "DF Roboto SemiBold"
    elem.fontSize = elem.fontSize or 10
    elem.outline = elem.outline or "SHADOW"
    elem.color = elem.color or {r = 1, g = 1, b = 1, a = 1}
    if elem.useClassColor == nil then elem.useClassColor = false end

    -- Font (LSM-aware dropdown). Use GUI:CreateFontDropdown if available;
    -- otherwise fall back to a generic dropdown listing the current font only.
    local fontDrop
    if GUI.CreateFontDropdown then
        fontDrop = GUI:CreateFontDropdown(parent, L["Font"], elem, "font", function() end)
    else
        fontDrop = GUI:CreateDropdown(parent, L["Font"], {[elem.font] = elem.font}, elem, "font", function() end)
    end
    fontDrop:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    y = y - FIELD_ROW_HEIGHT

    -- Size
    local sizeSlider = GUI:CreateSlider(parent, L["Size"], 6, 40, 1, elem, "fontSize", function() end)
    sizeSlider:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    y = y - FIELD_ROW_HEIGHT

    -- Outline + Shadow
    local outlineDrop = GUI:CreateOutlineDropdown(parent, L["Outline"], elem, "outline", function() end)
    outlineDrop:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    y = y - FIELD_ROW_HEIGHT

    local shadowCheck = GUI:CreateShadowCheckbox(parent, L["Shadow"], elem, "outline", function() end)
    shadowCheck:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    y = y - FIELD_ROW_HEIGHT

    -- Color picker + Use Class Color toggle.
    -- CreateColorPicker signature: (parent, label, dbTable, dbKey, hasAlpha, callback, ...)
    local colorPicker = GUI:CreateColorPicker(parent, L["Color"], elem, "color", true, function() end)
    colorPicker:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)

    local classColorCheck = GUI:CreateCheckbox(parent, L["Use Class Color"], elem, "useClassColor", function()
        if elem.useClassColor then
            if colorPicker.Disable then colorPicker:Disable() end
            colorPicker:SetAlpha(0.4)
        else
            if colorPicker.Enable then colorPicker:Enable() end
            colorPicker:SetAlpha(1)
        end
    end)
    classColorCheck:SetPoint("LEFT", colorPicker, "RIGHT", 16, 0)

    -- Apply initial grayed state if class color is on
    if elem.useClassColor then
        if colorPicker.Disable then colorPicker:Disable() end
        colorPicker:SetAlpha(0.4)
    end
    y = y - FIELD_ROW_HEIGHT

    return y - SECTION_GAP
end

-- Build the Anchor To dropdown's options table. Returns {key=label} where
-- the FRAME sentinel anchors to the unit frame and integer-string keys
-- anchor to another element's id. Excludes self and any transitive
-- descendant (cycle prevention).
local function BuildAnchorTargets(tdDB, currentElem)
    local descendants = {}
    local function MarkDescendants(rootID)
        for _, e in ipairs(tdDB.elements) do
            if e.anchorTo and tostring(e.anchorTo) == tostring(rootID) and not descendants[e.id] then
                descendants[e.id] = true
                MarkDescendants(e.id)
            end
        end
    end
    MarkDescendants(currentElem.id)

    local opts = { FRAME = L["Frame"] }
    for _, other in ipairs(tdDB.elements) do
        if other.id ~= currentElem.id and not descendants[other.id] then
            local optLabel
            if other.label and other.label ~= "" then
                optLabel = other.label
            else
                local ct = FindContentType(other.contentType)
                optLabel = (ct and ct.label or other.contentType) .. " #" .. other.id
            end
            opts[tostring(other.id)] = optLabel
        end
    end
    return opts
end

-- Returns the y-offset where the next section should start (negative, goes down).
-- `card` is accepted for signature consistency with BuildContentSection; not used.
local function BuildPositionSection(GUI, parent, elem, tdDB, card, yStart)
    local label = CreateSectionLabel(GUI, parent, L["Position"])
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yStart)
    local y = yStart - SECTION_LABEL_HEIGHT

    -- Defaults
    elem.anchor = elem.anchor or "CENTER"
    elem.offsetX = elem.offsetX or 0
    elem.offsetY = elem.offsetY or 0
    elem.frameLevel = elem.frameLevel or 25
    elem.frameStrata = elem.frameStrata or "INHERIT"
    elem.anchorTo = elem.anchorTo or "FRAME"

    -- Anchor grid on the left
    local grid = CreateAnchorGrid(GUI, parent, elem)
    grid:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y - 4)
    local gridLabel = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(gridLabel, 8, "")
    gridLabel:SetText(L["Anchor"])
    gridLabel:SetPoint("TOP", grid, "BOTTOM", 0, -2)
    gridLabel:SetTextColor(0.6, 0.6, 0.6)

    -- Offsets / frame settings on the right
    local rightX = 100
    local xSlider = GUI:CreateSlider(parent, L["Offset X"], -200, 200, 1, elem, "offsetX", function() end)
    xSlider:SetPoint("TOPLEFT", parent, "TOPLEFT", rightX, y)
    y = y - FIELD_ROW_HEIGHT

    local ySlider = GUI:CreateSlider(parent, L["Offset Y"], -200, 200, 1, elem, "offsetY", function() end)
    ySlider:SetPoint("TOPLEFT", parent, "TOPLEFT", rightX, y)
    y = y - FIELD_ROW_HEIGHT

    local lvlSlider = GUI:CreateSlider(parent, L["Frame Level"], 1, 200, 1, elem, "frameLevel", function() end)
    lvlSlider:SetPoint("TOPLEFT", parent, "TOPLEFT", rightX, y)
    y = y - FIELD_ROW_HEIGHT

    local strataOpts = {
        INHERIT = L["Inherit"],
        LOW = "LOW",
        MEDIUM = "MEDIUM",
        HIGH = "HIGH",
        DIALOG = "DIALOG",
    }
    local strataDrop = GUI:CreateDropdown(parent, L["Frame Strata"], strataOpts, elem, "frameStrata", function() end)
    strataDrop:SetPoint("TOPLEFT", parent, "TOPLEFT", rightX, y)
    y = y - FIELD_ROW_HEIGHT

    -- Anchor To: target element (or the unit frame). Options are computed
    -- dynamically and exclude self + transitive descendants to prevent cycles.
    local anchorTargets = BuildAnchorTargets(tdDB, elem)
    local anchorToDrop = GUI:CreateDropdown(parent, L["Anchor To"], anchorTargets, elem, "anchorTo", function() end)
    anchorToDrop:SetPoint("TOPLEFT", parent, "TOPLEFT", rightX, y)
    y = y - FIELD_ROW_HEIGHT

    return y - SECTION_GAP
end

-- ============================================================
-- ADD ELEMENT PICKER
-- A floating dropdown: search input, category pill row, grouped list.
-- Calls onPick(typeKey) when the user selects a type. Closes on pick.
-- Click the Add Element button again to dismiss without picking.
-- ============================================================

-- BuildPicker is forward-declared above so BuildContentSection's group
-- branch can reference it. Assign the implementation to the upvalue.
function BuildPicker(GUI, parent, tdDB, onPick, excludeKey)
    local drop = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    drop:SetFrameStrata("FULLSCREEN_DIALOG")
    drop:SetClampedToScreen(true)
    drop:SetSize(280, 380)
    ApplyBackdrop(drop, C_BACKGROUND, C_BORDER)
    drop:Hide()

    -- ── Click-outside overlay ────────────────────────────────
    -- A transparent fullscreen catcher that closes the picker when the user
    -- clicks anywhere outside it. Pattern mirrors AuraDesigner's picker.
    local overlay = CreateFrame("Button", nil, UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN")  -- below FULLSCREEN_DIALOG so drop stays on top
    overlay:EnableMouse(true)
    overlay:Hide()
    overlay:SetScript("OnClick", function()
        drop:Hide()
    end)
    drop._overlay = overlay

    -- ESC closes the picker as well.
    drop:EnableKeyboard(true)
    drop:SetPropagateKeyboardInput(true)
    drop:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            drop:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- ── Search input ─────────────────────────────────────────
    local searchBox = CreateFrame("EditBox", nil, drop, "InputBoxTemplate")
    searchBox:SetSize(240, 20)
    searchBox:SetPoint("TOPLEFT", drop, "TOPLEFT", 16, -10)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject("ChatFontNormal")
    drop.searchBox = searchBox

    -- ── Pill row (category filters) ─────────────────────────
    -- Sized to the dropdown width minus side padding so flow-layout can wrap.
    local PILL_ROW_PAD = 16
    local pillRow = CreateFrame("Frame", nil, drop)
    pillRow:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -4, -6)
    pillRow:SetPoint("TOPRIGHT", drop, "TOPRIGHT", -PILL_ROW_PAD, 0)
    pillRow:SetHeight(18)
    local pills = {}

    local CHIP_H, CHIP_GAP, CHIP_ROW_GAP = 18, 4, 4

    local function MakePill(label, key)
        local p = CreateFrame("Button", nil, pillRow, "BackdropTemplate")
        p:SetHeight(CHIP_H)
        ApplyBackdrop(p, C_PANEL, C_BORDER)
        local fs = p:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(fs, 9, "")
        fs:SetPoint("CENTER")
        fs:SetText(label)
        p:SetWidth(fs:GetStringWidth() + 14)
        p.key = key
        p.fs = fs
        return p
    end

    pills[#pills+1] = MakePill(L["All"], "_all")
    for _, cat in ipairs(CONTENT_CATEGORIES) do
        pills[#pills+1] = MakePill(CONTENT_CATEGORY_LABELS[cat], cat)
    end

    -- Flow-layout: position pills with wrapping on parent resize
    local function LayoutPills()
        local maxW = pillRow:GetWidth()
        if maxW <= 0 then maxW = 260 end
        local cx, cy = 0, 0
        for _, btn in ipairs(pills) do
            local bw = btn:GetWidth()
            if cx > 0 and (cx + bw) > maxW then
                cx = 0
                cy = cy - (CHIP_H + CHIP_ROW_GAP)
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", pillRow, "TOPLEFT", cx, cy)
            cx = cx + bw + CHIP_GAP
        end
        pillRow:SetHeight(math.max(-cy + CHIP_H, CHIP_H))
    end
    LayoutPills()
    pillRow:SetScript("OnSizeChanged", LayoutPills)

    local activePill = "_all"
    local function ApplyPillState()
        for _, p in ipairs(pills) do
            if p.key == activePill then
                p:SetBackdropColor(0.2, 0.4, 0.7, 1)
                p:SetBackdropBorderColor(0.4, 0.7, 1, 1)
                p.fs:SetTextColor(1, 1, 1)
            else
                p:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, C_PANEL.a)
                p:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, C_BORDER.a)
                p.fs:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
        end
    end
    ApplyPillState()

    -- ── Scrolling list of items ─────────────────────────────
    -- Anchor to bottom of pillRow so wrapped pills push the list down correctly.
    local scrollFrame = CreateFrame("ScrollFrame", nil, drop, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", pillRow, "BOTTOMLEFT", 4, -6)
    scrollFrame:SetPoint("BOTTOMRIGHT", drop, "BOTTOMRIGHT", -20, 10)
    DF.GUI.StyleScrollBar(scrollFrame)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(current - delta * 20, self:GetVerticalScrollRange())))
    end)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(244, 1)
    scrollFrame:SetScrollChild(scrollChild)
    drop.scrollChild = scrollChild

    local itemPool = {}
    local function AcquireItem()
        for _, it in ipairs(itemPool) do
            if not it:IsShown() then return it end
        end
        local it = CreateFrame("Button", nil, scrollChild, "BackdropTemplate")
        it:SetSize(240, 16)
        it:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8"})
        it:SetBackdropColor(0.2, 0.4, 0.7, 0)
        local fs = it:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(fs, 10, "")
        fs:SetPoint("LEFT", it, "LEFT", 14, 0)
        it.fs = fs
        it:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.2, 0.4, 0.7, 0.3)
        end)
        it:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.2, 0.4, 0.7, 0)
        end)
        itemPool[#itemPool+1] = it
        return it
    end

    local headerPool = {}
    local function AcquireHeader()
        for _, h in ipairs(headerPool) do
            if not h:IsShown() then return h end
        end
        local h = scrollChild:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(h, 9, "")
        h:SetJustifyH("LEFT")
        headerPool[#headerPool+1] = h
        return h
    end

    local function HideAll()
        for _, it in ipairs(itemPool) do it:Hide() end
        for _, h in ipairs(headerPool) do h:Hide() end
    end

    local function RenderList()
        HideAll()
        local query = (searchBox:GetText() or ""):lower()
        query = query:match("^%s*(.-)%s*$") or ""

        local y = -2
        for _, cat in ipairs(CONTENT_CATEGORIES) do
            if activePill == "_all" or activePill == cat then
                local matches = {}
                for _, t in ipairs(CONTENT_TYPES) do
                    if t.category == cat and t.key ~= excludeKey then
                        if query == "" or t.label:lower():find(query, 1, true) then
                            matches[#matches+1] = t
                        end
                    end
                end
                if #matches > 0 then
                    local h = AcquireHeader()
                    h:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 8, y)
                    h:SetText(CONTENT_CATEGORY_LABELS[cat]:upper())
                    h:SetTextColor(0.5, 0.7, 1, 0.9)
                    h:Show()
                    y = y - 14
                    for _, t in ipairs(matches) do
                        local it = AcquireItem()
                        it:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 2, y)
                        it.fs:SetText(t.label)
                        it.fs:SetTextColor(0.95, 0.95, 0.95)
                        it:SetScript("OnClick", function()
                            drop:Hide()
                            if onPick then onPick(t.key) end
                        end)
                        it:Show()
                        y = y - 16
                    end
                    y = y - 4
                end
            end
        end
        scrollChild:SetHeight(math.max(1, -y + 4))
    end

    searchBox:SetScript("OnTextChanged", RenderList)

    for _, p in ipairs(pills) do
        p:SetScript("OnClick", function(self)
            activePill = self.key
            ApplyPillState()
            RenderList()
        end)
    end

    -- `side` is optional. "right" (default) anchors TOPRIGHT-to-BOTTOMRIGHT
    -- so the dropdown extends LEFT and DOWN — correct for buttons on the right
    -- side of the controls bar. "left" anchors TOPLEFT-to-BOTTOMLEFT so the
    -- dropdown extends RIGHT and DOWN — correct for the in-card Add Item
    -- button which sits on the LEFT of the card body.
    function drop:Open(anchor, side)
        searchBox:SetText("")
        activePill = "_all"
        ApplyPillState()
        RenderList()
        drop:ClearAllPoints()
        if side == "left" then
            drop:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
        else
            drop:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
        end
        drop:Show()
        if overlay then overlay:Show() end
        searchBox:SetFocus()
    end

    drop:SetScript("OnHide", function()
        if overlay then overlay:Hide() end
        searchBox:ClearFocus()
    end)

    return drop
end

-- ============================================================
-- ELEMENT CARD
-- A collapsible settings group representing one text element. Uses the
-- shared GUI:CreateSettingsGroup helper so the card matches the rest of
-- the addon's theming (arrow icon, theme accent color, bottom collapse bar).
-- Body sections: Content / Appearance / Position.
-- ============================================================

local function BuildCard(GUI, parent, elem, tdDB, state, page)
    local card = GUI:CreateSettingsGroup(parent, parent:GetWidth() - 4, {
        collapsible = true,
        onCollapseChanged = function(group)
            if DF.TextDesigner.RenderCardList then
                DF.TextDesigner.RenderCardList(group._GUI, group._page, group._tdDB, group._state)
            end
        end,
    })

    -- Context for callbacks (used by delete + reflow paths and the
    -- onCollapseChanged closure above)
    card._tdDB = tdDB
    card._state = state
    card._GUI = GUI
    card._page = page

    -- ── HEADER WIDGET ────────────────────────────────────────
    -- The helper expects the first AddWidget to be the header and looks for
    -- `widget.text` (a FontString) to attach the collapse arrow.
    local header = CreateFrame("Frame", nil, card)
    header:SetHeight(28)

    local ct = FindContentType(elem.contentType)
    -- Prefer the user-supplied label if set; otherwise fall back to the
    -- content type's display name. Same rule as BuildAnchorTargets.
    local displayName = (elem.label and elem.label ~= "" and elem.label)
        or (ct and ct.label)
        or elem.contentType
    local title = header:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(title, 11, "OUTLINE")
    title:SetPoint("LEFT", header, "LEFT", 24, 0)  -- 24 leaves room for the arrow icon
    title:SetText(displayName)
    title:SetTextColor(0.95, 0.95, 0.95)
    header.text = title  -- helper requires this to wire the collapse arrow
    card.title = title

    local meta = header:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(meta, 9, "")
    meta:SetPoint("LEFT", title, "RIGHT", 8, 0)
    meta:SetText("")
    meta:SetTextColor(0.55, 0.6, 0.7)
    card.meta = meta

    -- ── ACTION ICONS (right side of header) ──────────────────
    local ICON_SIZE = 18
    local ICON_GAP = 4
    local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

    -- Delete (rightmost)
    local deleteBtn = CreateFrame("Button", nil, header)
    deleteBtn:SetSize(ICON_SIZE, ICON_SIZE)
    deleteBtn:SetPoint("RIGHT", header, "RIGHT", -8, 0)
    local deleteIcon = deleteBtn:CreateTexture(nil, "OVERLAY")
    deleteIcon:SetAllPoints()
    deleteIcon:SetTexture(mediaPath .. "delete")
    deleteIcon:SetVertexColor(0.9, 0.4, 0.4)
    deleteBtn:SetScript("OnEnter", function() deleteIcon:SetVertexColor(1, 0.6, 0.6) end)
    deleteBtn:SetScript("OnLeave", function() deleteIcon:SetVertexColor(0.9, 0.4, 0.4) end)
    card.deleteBtn = deleteBtn

    -- Drag handle
    local dragBtn = CreateFrame("Button", nil, header)
    dragBtn:SetSize(ICON_SIZE, ICON_SIZE)
    dragBtn:SetPoint("RIGHT", deleteBtn, "LEFT", -ICON_GAP, 0)
    local dragIcon = dragBtn:CreateTexture(nil, "OVERLAY")
    dragIcon:SetAllPoints()
    dragIcon:SetTexture(mediaPath .. "menu")
    dragIcon:SetVertexColor(0.7, 0.7, 0.7)
    card.dragBtn = dragBtn

    -- Visibility toggle (eye)
    local eyeBtn = CreateFrame("Button", nil, header)
    eyeBtn:SetSize(ICON_SIZE, ICON_SIZE)
    eyeBtn:SetPoint("RIGHT", dragBtn, "LEFT", -ICON_GAP, 0)
    local eyeIcon = eyeBtn:CreateTexture(nil, "OVERLAY")
    eyeIcon:SetAllPoints()
    local function updateEyeIcon()
        if elem.enabled then
            eyeIcon:SetTexture(mediaPath .. "visibility")
            eyeIcon:SetVertexColor(0.95, 0.95, 0.95)
        else
            eyeIcon:SetTexture(mediaPath .. "visibility_off")
            eyeIcon:SetVertexColor(0.45, 0.45, 0.45)
        end
    end
    updateEyeIcon()
    card.eyeBtn = eyeBtn

    -- Lift action icons above the header's OnMouseDown collapse handler so
    -- clicks on them don't toggle the card. RegisterForClicks + a higher
    -- frame level keep them isolated from the header.
    for _, btn in ipairs({eyeBtn, dragBtn, deleteBtn}) do
        btn:RegisterForClicks("LeftButtonUp")
        btn:SetFrameLevel(header:GetFrameLevel() + 5)
    end

    -- Wire visibility toggle
    eyeBtn:SetScript("OnClick", function()
        elem.enabled = not elem.enabled
        updateEyeIcon()
        DF:Debug("TD", "Element %d enabled=%s", elem.id, tostring(elem.enabled))
    end)

    -- Wire delete (themed popup)
    deleteBtn:SetScript("OnClick", function()
        local capturedTdDB = card._tdDB
        local capturedState = card._state
        local capturedGUI = card._GUI
        local capturedPage = card._page
        DF:ShowPopupAlert({
            title = L["Delete Text Element"],
            message = L["Delete this text element?"],
            buttons = {
                {
                    label = L["Yes"],
                    onClick = function()
                        if not capturedTdDB or not capturedState then return end
                        for i, e in ipairs(capturedTdDB.elements) do
                            if e.id == elem.id then
                                table.remove(capturedTdDB.elements, i)
                                break
                            end
                        end
                        capturedState.cardFrames[elem.id] = nil
                        card:Hide()
                        card:SetParent(nil)
                        if DF.TextDesigner.RenderCardList then
                            DF.TextDesigner.RenderCardList(capturedGUI, capturedPage, capturedTdDB, capturedState)
                        end
                        DF:Debug("TD", "Deleted element id=%d (remaining=%d)",
                            elem.id, #capturedTdDB.elements)
                    end,
                },
                { label = L["No"] },
            },
        })
    end)

    -- Wire drag-to-reorder.
    -- Mirrors the OnMouseDown / OnMouseUp / OnUpdate pattern used by
    -- GUI:CreateRoleOrderList (GUI/GUI.lua:4438-4518) so the dragged card
    -- follows the cursor live and other cards reflow underneath it as the
    -- drop position changes. The drag handle is the grip icon (dragBtn);
    -- the card itself owns the OnUpdate that moves it with the cursor.
    local dragOffsetY = 0
    local CARD_GAP_DRAG = 6  -- must match CARD_GAP in RenderCardList

    dragBtn:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        card._dragging = true
        local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local cardTop = card:GetTop()
        if cardTop then
            dragOffsetY = cardTop - cursorY
        else
            dragOffsetY = 0
        end
        local listChild = card._state and card._state.listChild
        local baseLevel = (listChild and listChild:GetFrameLevel()) or card:GetFrameLevel()
        card:SetFrameLevel(baseLevel + 10)
        card:SetAlpha(0.85)
        dragIcon:SetVertexColor(1, 1, 1)
        DF:Debug("TD", "Drag start id=%d", elem.id)
    end)

    dragBtn:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if not card._dragging then return end
        card._dragging = false
        card:SetAlpha(1)
        dragIcon:SetVertexColor(0.7, 0.7, 0.7)
        -- RenderCardList re-anchors every card to its index position and
        -- restores frame level / visibility, so we don't need to undo
        -- anything manually here.
        if DF.TextDesigner.RenderCardList then
            DF.TextDesigner.RenderCardList(card._GUI, card._page, card._tdDB, card._state)
        end
    end)

    card:SetScript("OnUpdate", function(self, elapsed)
        if not card._dragging then return end
        local capturedTdDB = card._tdDB
        local capturedState = card._state
        if not capturedTdDB or not capturedState or not capturedState.listChild then return end

        local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local listChildTop = capturedState.listChild:GetTop()
        if not listChildTop then return end

        -- Position the dragged card under the cursor (preserving the click
        -- offset so it doesn't snap to the cursor origin).
        local targetY = cursorY + dragOffsetY
        local offsetFromTop = listChildTop - targetY
        -- Clamp so the card stays inside the list child bounds.
        local listHeight = capturedState.listChild:GetHeight()
        local cardHeight = card:GetHeight()
        local maxOffset = math.max(0, listHeight - cardHeight)
        offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))

        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", capturedState.listChild, "TOPLEFT", 2, -offsetFromTop)
        card:SetPoint("TOPRIGHT", capturedState.listChild, "TOPRIGHT", -2, -offsetFromTop)

        -- Compute the target drop index from cursor position relative to
        -- the other cards.
        local dropIndex
        for i, e in ipairs(capturedTdDB.elements) do
            local other = capturedState.cardFrames[e.id]
            if other and other ~= card and other:IsShown() then
                local otherTop = other:GetTop()
                if otherTop and cursorY > otherTop then
                    dropIndex = i
                    break
                end
            end
        end
        if not dropIndex then dropIndex = #capturedTdDB.elements end

        -- Find the dragged card's current index in the db.
        local currentIdx
        for i, e in ipairs(capturedTdDB.elements) do
            if e.id == elem.id then currentIdx = i; break end
        end
        if not currentIdx then return end

        -- If the drop slot has moved, reorder the db live and reflow the
        -- OTHER cards. The dragged card itself stays under the cursor —
        -- the next OnUpdate tick re-sets its position from the cursor, so
        -- we deliberately don't reposition it here.
        if currentIdx ~= dropIndex then
            local moved = table.remove(capturedTdDB.elements, currentIdx)
            table.insert(capturedTdDB.elements, math.min(dropIndex, #capturedTdDB.elements + 1), moved)
            local y = 0
            for _, e in ipairs(capturedTdDB.elements) do
                local sibling = capturedState.cardFrames[e.id]
                if sibling then
                    if sibling.LayoutChildren then sibling:LayoutChildren() end
                    if sibling ~= card then
                        sibling:ClearAllPoints()
                        sibling:SetPoint("TOPLEFT", capturedState.listChild, "TOPLEFT", 2, y)
                        sibling:SetPoint("TOPRIGHT", capturedState.listChild, "TOPRIGHT", -2, y)
                    end
                    y = y - sibling:GetHeight() - CARD_GAP_DRAG
                end
            end
        end
    end)

    -- Register header as the FIRST widget — wires the helper's collapse arrow
    -- + OnMouseDown handler onto it.
    card:AddWidget(header, 28)

    -- Override the helper's BOTTOMLEFT positioning of the title FontString.
    -- AddWidget pins header.text to BOTTOMLEFT (intended for CreateHeader's
    -- 25-px header layout), which leaves the title visually low in our
    -- 28-px header bar with centered action icons. Re-anchor to LEFT so
    -- the title vertically centers. The collapse arrow is anchored to the
    -- text's LEFT (see GUI.lua:478) so it follows automatically.
    header.text:ClearAllPoints()
    header.text:SetPoint("LEFT", header, "LEFT", 24, 0)

    -- ── BODY SECTIONS ────────────────────────────────────────
    -- Each section is built into its own Frame, sized to its content, and
    -- handed to the helper's LayoutChildren for vertical stacking. AddWidget
    -- reparents the widget to the group, so each section needs to be a
    -- self-contained Frame that holds its own widgets.
    local contentFrame = CreateFrame("Frame", nil, card)
    local contentY = BuildContentSection(GUI, contentFrame, elem, tdDB, state, page, card, -4)
    local contentHeight = math.max(1, -contentY + 4)
    contentFrame:SetHeight(contentHeight)
    card:AddWidget(contentFrame, contentHeight)

    local appearanceFrame = CreateFrame("Frame", nil, card)
    local appearanceY = BuildAppearanceSection(GUI, appearanceFrame, elem, card, -4)
    local appearanceHeight = math.max(1, -appearanceY + 4)
    appearanceFrame:SetHeight(appearanceHeight)
    card:AddWidget(appearanceFrame, appearanceHeight)

    local positionFrame = CreateFrame("Frame", nil, card)
    local positionY = BuildPositionSection(GUI, positionFrame, elem, tdDB, card, -4)
    local positionHeight = math.max(1, -positionY + 4)
    positionFrame:SetHeight(positionHeight)
    card:AddWidget(positionFrame, positionHeight)

    card:LayoutChildren()

    -- Update the header meta line with current anchor + offset summary
    function card:UpdateMeta()
        meta:SetText((elem.anchor or "CENTER") .. " · " .. (elem.offsetX or 0) .. "," .. (elem.offsetY or 0))
    end
    card:UpdateMeta()

    return card
end

-- ============================================================
-- CARD LIST RENDERER
-- Iterates db.elements in order, builds/positions cards. Uses a pool
-- to avoid creating/destroying card frames on every render.
-- ============================================================

local function RenderCardList(GUI, page, tdDB, state)
    -- Ensure listChild width matches the container — cards anchor TOPLEFT/TOPRIGHT
    -- to listChild, so if its width is 0/1 (e.g. before lazy sizing kicks in)
    -- they'll end up with negative width and render invisibly.
    -- Guard against transient 0: don't overwrite a good width with nothing.
    local cw = state.listContainer:GetWidth()
    if cw and cw > 1 then
        state.listChild:SetWidth(cw)
    end

    -- Hide all existing card frames first
    for _, card in pairs(state.cardFrames) do
        card:Hide()
    end

    if #tdDB.elements == 0 then
        if state.emptyMsg then state.emptyMsg:Show() end
        if state.emptyHint then state.emptyHint:Show() end
        state.listChild:SetHeight(1)
        return
    end

    if state.emptyMsg then state.emptyMsg:Hide() end
    if state.emptyHint then state.emptyHint:Hide() end

    local y = 0
    local CARD_GAP = 6
    for _, elem in ipairs(tdDB.elements) do
        local card = state.cardFrames[elem.id]
        if not card then
            card = BuildCard(GUI, state.listChild, elem, tdDB, state, page)
            state.cardFrames[elem.id] = card
        end
        -- Let the helper recompute its own height. LayoutChildren walks
        -- groupChildren and honors `collapsed` to show only the header,
        -- so card:GetHeight() afterwards is the authoritative height.
        if card.LayoutChildren then card:LayoutChildren() end
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", state.listChild, "TOPLEFT", 2, y)
        card:SetPoint("TOPRIGHT", state.listChild, "TOPRIGHT", -2, y)
        card:Show()
        y = y - card:GetHeight() - CARD_GAP
    end
    state.listChild:SetHeight(math.max(1, -y + 4))
end

DF.TextDesigner.RenderCardList = RenderCardList  -- exposed for Task 6+

-- The page state across builder invocations. Cached on the page frame.
local function GetState(page)
    page.dfTD = page.dfTD or {
        cardFrames = {},     -- pool of card frames keyed by elementID
        pickerFrame = nil,   -- the Add Element dropdown (created lazily)
    }
    return page.dfTD
end

-- ============================================================
-- BUILD ENTRYPOINT
-- ============================================================

function DF.BuildTextDesignerPage(GUI, page, db)
    DF.TextDesigner:EnsureDB(db)
    local tdDB = db.textDesigner
    local state = GetState(page)

    -- Override RefreshStates: TD doesn't use the Add() widget helper, so the
    -- default calculation would shrink page.child to ~40px tall, collapsing
    -- our list panel into an inside-out degenerate rect. Set page.child to
    -- the full page viewport instead. (Mirrors AuraDesigner/Options.lua:5849.)
    -- Installed every call (even when short-circuited) because RefreshStates
    -- may be invoked freshly on tab re-open.
    page.RefreshStates = function(self)
        if self.child then
            self.child:SetHeight(self:GetHeight())
            if GUI.contentFrame then
                self.child:SetWidth(GUI.contentFrame:GetWidth() - 30)
            end
        end
    end

    if state.built then return end
    state.built = true

    -- ── TAB-LEVEL CONTROLS BAR ───────────────────────────────
    -- Master enable toggle + Add Element button, side by side at top.
    local controlsBar = CreateFrame("Frame", nil, page.child)
    controlsBar:SetHeight(32)
    controlsBar:SetPoint("TOPLEFT", page.child, "TOPLEFT", 10, -10)
    controlsBar:SetPoint("TOPRIGHT", page.child, "TOPRIGHT", -10, -10)

    -- Master toggle
    local enableCheck = GUI:CreateCheckbox(
        controlsBar,
        L["Enable Text Designer"],
        tdDB,
        "enabled",
        function() DF:Debug("TD", "Enable Text Designer = %s", tostring(tdDB.enabled)) end
    )
    enableCheck:SetPoint("LEFT", controlsBar, "LEFT", 0, 0)

    -- Add Element button — opens the picker dropdown.
    local addBtn
    addBtn = GUI:CreateButton(controlsBar, "+ " .. L["Add Text Element"], 160, 22, function()
        if not state.pickerFrame then
            state.pickerFrame = BuildPicker(GUI, page, tdDB, function(typeKey)
                -- Create a new element instance
                local id = tdDB.nextElementID
                tdDB.nextElementID = id + 1
                local elem = {
                    id = id,
                    contentType = typeKey,
                    enabled = true,
                }
                table.insert(tdDB.elements, elem)
                DF:Debug("TD", "Added element id=%d type=%s (total=%d)",
                    id, typeKey, #tdDB.elements)
                -- Hide empty state if it's still visible
                if state.emptyMsg then state.emptyMsg:Hide() end
                if state.emptyHint then state.emptyHint:Hide() end
                RenderCardList(GUI, page, tdDB, state)
            end)
        end
        if state.pickerFrame:IsShown() then
            state.pickerFrame:Hide()
        else
            state.pickerFrame:Open(addBtn)
        end
    end)
    addBtn:SetPoint("RIGHT", controlsBar, "RIGHT", 0, 0)
    state.addBtn = addBtn

    -- ── CARD LIST AREA ───────────────────────────────────────
    -- A bordered panel hosts the section header and the scrollable card list.
    -- Empty-state message centers inside the panel when no elements exist.
    local listHeader = page.child:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(listHeader, 9, "OUTLINE")
    listHeader:SetText(L["Text Elements"]:upper())
    listHeader:SetTextColor(0.5, 0.7, 1, 0.9)
    listHeader:SetPoint("TOPLEFT", controlsBar, "BOTTOMLEFT", 12, -6)

    local listPanel = CreateFrame("Frame", nil, page.child, "BackdropTemplate")
    listPanel:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", -12, -4)
    listPanel:SetPoint("BOTTOMRIGHT", page.child, "BOTTOMRIGHT", -10, 10)
    ApplyBackdrop(listPanel, C_PANEL_VISIBLE, C_BORDER_VISIBLE)

    local listContainer = CreateFrame("ScrollFrame", nil, listPanel, "ScrollFrameTemplate")
    listContainer:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 6, -6)
    listContainer:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -22, 8)
    DF.GUI.StyleScrollBar(listContainer)
    listContainer:EnableMouseWheel(true)
    listContainer:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(current - delta * 20, self:GetVerticalScrollRange())))
    end)

    local listChild = CreateFrame("Frame", nil, listContainer)
    -- Compute initial width from page.child (which is sized correctly thanks to
    -- the RefreshStates override above). listContainer:GetWidth() returns 0 at
    -- creation time because layout hasn't run yet, so we can't rely on it.
    -- Fall back to a sane default if page.child isn't sized yet.
    local initialW = page.child:GetWidth()
    if initialW < 100 then
        initialW = (GUI.contentFrame and GUI.contentFrame:GetWidth() or 600) - 30
    end
    listChild:SetSize(math.max(1, initialW - 40), 1)
    listContainer:SetScrollChild(listChild)
    -- Keep listChild width in sync with listContainer when its size changes.
    -- Guard against transient 0 values that would wipe out a good width.
    listContainer:HookScript("OnSizeChanged", function(self, w, h)
        if w and w > 1 then
            listChild:SetWidth(w)
        end
    end)
    state.listPanel = listPanel
    state.listContainer = listContainer
    state.listChild = listChild

    local emptyMsg = listPanel:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(emptyMsg, 12, "")
    emptyMsg:SetPoint("CENTER", listContainer, "CENTER", 0, 0)
    emptyMsg:SetText(L["No text elements yet. Click '+ Add Text Element' to create one."])
    emptyMsg:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.8)
    state.emptyMsg = emptyMsg

    local emptyHint = listPanel:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(emptyHint, 10, "")
    emptyHint:SetText(L["Use the + button above to add your first element."])
    emptyHint:SetPoint("TOP", emptyMsg, "BOTTOM", 0, -8)
    emptyHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    state.emptyHint = emptyHint

    -- Initial render — populate any existing elements
    RenderCardList(GUI, page, tdDB, state)
end
