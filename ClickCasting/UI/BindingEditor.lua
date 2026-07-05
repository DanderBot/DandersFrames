local addonName, DF = ...

-- Get module namespace
local CC = DF.ClickCast
local L = DF.L
local format = string.format

-- Local aliases for shared constants (defined in Constants.lua)
local DEFAULT_BINDING_SCOPE = CC.DEFAULT_BINDING_SCOPE
local DEFAULT_BINDING_COMBAT = CC.DEFAULT_BINDING_COMBAT
local DEFAULT_TARGET_TYPE = CC.DEFAULT_TARGET_TYPE
local TARGET_INFO = CC.TARGET_INFO
local FRAME_INFO = CC.FRAME_INFO
local FALLBACK_INFO = CC.FALLBACK_INFO
local COMBAT_INFO = CC.COMBAT_INFO

-- Local alias for shared UI tables (defined in UI/Main.lua)
-- spellCells is now accessed via CC.spellCells

-- Local alias for UI constants (defined in UI/Main.lua)
local BINDING_ROW_HEIGHT = CC.BINDING_ROW_HEIGHT or 48

-- Local alias for helper functions (defined in Bindings.lua)
local function GetSpellDisplayInfo(a, b) 
    if CC.GetSpellDisplayInfo then 
        return CC.GetSpellDisplayInfo(a, b) 
    else
        -- Fallback if function not available
        local name = b or (a and C_Spell.GetSpellName and C_Spell.GetSpellName(a)) or "Unknown"
        local icon = a and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(a) or 134400
        return name, icon, a
    end
end

-- Local alias for helper functions (defined in UI/Main.lua)
local function GetFallbackDisplayText(f) return CC.GetFallbackDisplayText and CC.GetFallbackDisplayText(f) or nil end

-- Local alias for helper functions (defined in UI/ProfilesPanel.lua)
local function ShowPopupOnTop(name) return CC.ShowPopupOnTop and CC.ShowPopupOnTop(name) or StaticPopup_Show(name) end

-- ADD/EDIT BINDING DIALOG
-- ============================================================

local addBindingDialog = nil

-- ============================================================

-- ACTIVE BINDINGS ROW CREATION
-- =========================================================================
function CC:CreateBindingRow(parent, binding, index)
    local C = self.UI_COLORS
    local themeColor = C.theme
    
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(BINDING_ROW_HEIGHT - 2)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    row:SetBackdropColor(C.element.r, C.element.g, C.element.b, 0.8)
    row:SetBackdropBorderColor(C.border.r, C.border.g, C.border.b, 0.5)
    
    -- Icon (larger to fill height better)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("LEFT", 4, 0)
    
    -- Icon for the binding's action (shared resolver in Bindings.lua)
    icon:SetTexture(CC:GetBindingDisplayIcon(binding))
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon
    
    -- Delete button (far right)
    local deleteBtn = CreateFrame("Button", nil, row)
    deleteBtn:SetSize(20, 20)
    deleteBtn:SetPoint("RIGHT", -4, 0)
    
    local deleteIcon = deleteBtn:CreateTexture(nil, "OVERLAY")
    deleteIcon:SetPoint("CENTER")
    deleteIcon:SetSize(10, 10)
    deleteIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
    deleteIcon:SetVertexColor(C.textDim.r, C.textDim.g, C.textDim.b)
    
    deleteBtn:SetScript("OnEnter", function()
        deleteIcon:SetVertexColor(1, 0.3, 0.3)
    end)
    deleteBtn:SetScript("OnLeave", function()
        deleteIcon:SetVertexColor(C.textDim.r, C.textDim.g, C.textDim.b)
    end)
    deleteBtn:SetScript("OnClick", function()
        for i, b in ipairs(CC.db.bindings) do
            if b == binding then
                table.remove(CC.db.bindings, i)
                break
            end
        end
        CC:ApplyBindings()
        CC:RefreshActiveBindings()
        CC:RefreshSpellGrid(true)  -- Skip scroll reset to maintain position
    end)
    row.deleteBtn = deleteBtn
    
    -- Format keybind display
    local bindText = ""
    if binding.bindType == "mouse" then
        local modDisplay = ""
        if binding.modifiers and binding.modifiers ~= "" then
            local mods = binding.modifiers:lower()
            if mods:find("shift") then modDisplay = modDisplay .. "Shift+" end
            if mods:find("ctrl") then modDisplay = modDisplay .. "Ctrl+" end
            if mods:find("alt") then modDisplay = modDisplay .. "Alt+" end
            if mods:find("meta") then modDisplay = modDisplay .. "Cmd+" end
        end
        local buttonName = CC.BUTTON_DISPLAY_NAMES[binding.button] or binding.button
        bindText = modDisplay .. buttonName
    elseif binding.bindType == "key" then
        local modDisplay = ""
        if binding.modifiers and binding.modifiers ~= "" then
            local mods = binding.modifiers:lower()
            if mods:find("shift") then modDisplay = modDisplay .. "Shift+" end
            if mods:find("ctrl") then modDisplay = modDisplay .. "Ctrl+" end
            if mods:find("alt") then modDisplay = modDisplay .. "Alt+" end
            if mods:find("meta") then modDisplay = modDisplay .. "Cmd+" end
        end
        local keyName = CC.KEY_DISPLAY_NAMES[binding.key] or binding.key
        bindText = modDisplay .. keyName
    elseif binding.bindType == "scroll" then
        local modDisplay = ""
        if binding.modifiers and binding.modifiers ~= "" then
            local mods = binding.modifiers:lower()
            if mods:find("shift") then modDisplay = modDisplay .. "Shift+" end
            if mods:find("ctrl") then modDisplay = modDisplay .. "Ctrl+" end
            if mods:find("alt") then modDisplay = modDisplay .. "Alt+" end
            if mods:find("meta") then modDisplay = modDisplay .. "Cmd+" end
        end
        local scrollName = CC.SCROLL_DISPLAY_NAMES[binding.key] or binding.key
        bindText = modDisplay .. scrollName
    end
    
    -- Keybind text (aligned with spell name on top line)
    local keybind = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    keybind:SetPoint("TOPRIGHT", row, "TOPRIGHT", -28, -6)
    keybind:SetJustifyH("RIGHT")
    keybind:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    keybind:SetText(bindText)
    row.keybind = keybind
    row.keybindText = bindText  -- Store for collapsed mode
    
    -- Content area - two lines: spell name on top, targeting info below
    local displayName = CC:GetActionDisplayString(binding)
    
    -- Spell name (top line, aligned with keybind)
    local name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -4)
    name:SetPoint("RIGHT", keybind, "LEFT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetText(displayName)
    name:SetTextColor(C.text.r, C.text.g, C.text.b)
    name:SetWordWrap(false)
    row.name = name
    
    -- Targeting info (bottom line, below spell name) - human readable format
    -- Hide fallback info for macros since they handle their own targeting
    local actionType = binding.actionType or ""
    local isMacro = (actionType == "macro") or (binding.macroId ~= nil)
    local fallback = binding.fallback or {}
    local fallbackText = isMacro and nil or GetFallbackDisplayText(fallback)
    -- Fall back to the legacy loadCombat field for freshly-added bindings (the
    -- loadCombat -> combat migration only runs at profile load); map its vocabulary.
    local combatSetting = binding.combat
        or (binding.loadCombat == "combat" and "incombat")
        or (binding.loadCombat == "nocombat" and "outofcombat")
        or "always"
    
    local targetingInfo = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    targetingInfo:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
    targetingInfo:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -28, 4)
    targetingInfo:SetJustifyH("LEFT")
    targetingInfo:SetJustifyV("TOP")
    targetingInfo:SetTextColor(C.textDim.r, C.textDim.g, C.textDim.b)
    targetingInfo:SetWordWrap(true)
    
    -- Build targeting description
    local targetParts = {}
    if fallbackText then
        table.insert(targetParts, fallbackText)
    end
    
    -- Add combat state if not "always"
    if combatSetting == "incombat" then
        table.insert(targetParts, L["Combat Only"])
    elseif combatSetting == "outofcombat" then
        table.insert(targetParts, L["Out of combat"])
    end
    
    if #targetParts > 0 then
        targetingInfo:SetText(table.concat(targetParts, " • "))
    else
        targetingInfo:SetText("")
    end
    row.targetingInfo = targetingInfo
    
    row.binding = binding
    row.bindingIndex = index
    
    -- Hover effect and tooltip
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.element.r + 0.08, C.element.g + 0.08, C.element.b + 0.08, 1)
        self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(displayName, 1, 1, 1)
        GameTooltip:AddLine(bindText, themeColor.r, themeColor.g, themeColor.b)
        
        -- Show targeting info (not for macros - they handle their own targeting)
        if fallbackText and not isMacro then
            GameTooltip:AddLine(format(L["Targeting: %s"], fallbackText), C.textDim.r, C.textDim.g, C.textDim.b)
        end
        
        -- Show combat state
        if combatSetting == "incombat" then
            GameTooltip:AddLine(L["Combat Only"], C.combat.r, C.combat.g, C.combat.b)
        elseif combatSetting == "outofcombat" then
            GameTooltip:AddLine(L["Out of Combat Only"], C.nocombat.r, C.nocombat.g, C.nocombat.b)
        end
        
        -- Show frames info
        local frames = binding.frames or { dandersFrames = true, otherFrames = true }
        local framesParts = {}
        if frames.dandersFrames then table.insert(framesParts, "DandersFrames") end
        if frames.otherFrames then table.insert(framesParts, L["Other Frames"]) end
        local framesText = format(L["Frames: %s"], #framesParts > 0 and table.concat(framesParts, ", ") or "None")
        GameTooltip:AddLine(framesText, 0.6, 0.6, 0.6)
        
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Click to edit"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.element.r, C.element.g, C.element.b, 0.8)
        self:SetBackdropBorderColor(C.border.r, C.border.g, C.border.b, 0.5)
        GameTooltip:Hide()
    end)
    
    -- Click handler - open edit panel
    row:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            -- Get icon for this binding based on action type
            local bindingIcon = nil
            local actionType = binding.actionType or CC.ACTION_TYPES.SPELL
            
            if actionType == "target" then
                bindingIcon = "Interface\\CURSOR\\Crosshairs"
            elseif actionType == "menu" then
                bindingIcon = "Interface\\Buttons\\UI-GuildButton-OfficerNote-Up"
            elseif actionType == "focus" then
                bindingIcon = "Interface\\Icons\\Ability_Hunter_MasterMarksman"
            elseif actionType == "assist" then
                bindingIcon = "Interface\\Icons\\Ability_Hunter_SniperShot"
            elseif binding.spellId or binding.spellName then
                -- Get current display icon (accounts for talent overrides)
                local _, displayIcon = GetSpellDisplayInfo(binding.spellId, binding.spellName)
                bindingIcon = displayIcon
            elseif binding.macroId then
                local macro = CC:GetMacroById(binding.macroId)
                if macro then
                    -- Try auto-detect first, then stored icon
                    bindingIcon = CC:GetIconFromMacroBody(macro.body)
                    if not bindingIcon and macro.icon and type(macro.icon) == "number" and macro.icon > 0 then
                        bindingIcon = macro.icon
                    end
                end
            end
            
            -- Build spell data from binding - use current display name/icon for overrides
            local displayName, displayIcon, displaySpellId = GetSpellDisplayInfo(binding.spellId, binding.spellName)
            local spellInfo = {
                name = displayName or binding.spellName or binding.macroName or binding.actionType,
                spellId = binding.spellId,  -- Keep base spell ID for binding
                spellName = binding.spellName,  -- Keep base spell name for macro
                icon = displayIcon or bindingIcon,
                isMacro = actionType == CC.ACTION_TYPES.MACRO,
                macroId = binding.macroId,
                actionType = actionType,
                displaySpellId = displaySpellId,  -- Current override spell ID for tooltips
            }
            
            -- Open edit panel with existing binding
            CC:ShowEditBindingPanel(spellInfo, binding, self.bindingIndex)
        end
    end)
    
    return row
end

-- =========================================================================

-- EDIT BINDING PANEL (Full binding editor with scope/combat options)
-- ============================================================

function CC:CreateEditBindingPanel()
    if self.editBindingPanel then return end
    
    local themeColor = CC.ACCENT
    -- Shared palette (same r/g/b as the GUI.lua locals; alpha is supplied per call site).
    local C_BACKGROUND = DF.GUI.Colors.background
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim  -- align with the norm (0.6) instead of a bespoke 0.5

    -- Main panel
    local panel = CreateFrame("Frame", "DFEditBindingPanel", UIParent, "BackdropTemplate")
    panel:SetSize(320, 480)  -- Start at collapsed height
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetFrameLevel(100)
    DF.GUI:CreatePanelBackdrop(panel, {
        bgAlpha = 0.98,
        borderColor = themeColor,
    })
    panel:Hide()
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    
    -- Title bar
    local titleBar = CreateFrame("Frame", nil, panel)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetHeight(28)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() panel:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
    
    local title = titleBar:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    title:SetText(L["Edit Binding"])
    title:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    panel.title = title
    
    -- Close button
    local closeBtn = DF.GUI:CreateCloseButton(titleBar, {
        size = 20,
        onClick = function() CC:HideEditBindingPanel() end,
    })
    closeBtn:SetPoint("RIGHT", -4, 0)

    -- Spell icon and name section
    local iconFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    iconFrame:SetPoint("TOPLEFT", 12, -36)
    iconFrame:SetSize(36, 36)
    DF.GUI:CreateElementBackdrop(iconFrame, {
        bgColor = {0, 0, 0, 1},
        borderColor = {C_BORDER.r, C_BORDER.g, C_BORDER.b, 1},
    })
    
    local icon = iconFrame:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    panel.icon = icon
    
    local spellName = panel:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    spellName:SetPoint("LEFT", iconFrame, "RIGHT", 10, 0)
    spellName:SetPoint("RIGHT", -12, 0)
    spellName:SetJustifyH("LEFT")
    spellName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    panel.spellName = spellName
    
    -- Divider
    local div1 = panel:CreateTexture(nil, "ARTWORK")
    div1:SetPoint("TOPLEFT", 12, -80)
    div1:SetPoint("TOPRIGHT", -12, -80)
    div1:SetHeight(1)
    div1:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    -- Binding section
    local bindLabel = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    bindLabel:SetPoint("TOPLEFT", 12, -90)
    bindLabel:SetText(L["Binding:"])
    bindLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Resting chrome + hover (accent border/wash) from the shared styler (Binds
    -- keeps its green accent). This is ALSO a live key-capture target: the OnClick/
    -- OnMouseWheel capture handlers and the green capturing-border hold are wired
    -- below. The capture border (set directly in Start/StopBindingCapture) is
    -- re-asserted in an OnLeave HOOK so StyleButton's neutral reset can't clobber
    -- the hold while the mouse leaves mid-capture.
    local bindButton = CreateFrame("Button", nil, panel, "BackdropTemplate")
    bindButton:SetPoint("LEFT", bindLabel, "RIGHT", 10, 0)
    DF.GUI:StyleButton(bindButton, {
        width = 150, height = 26,
        accent = CC.ACCENT,
        text = L["Click to bind..."],
        font = "DFFontHighlight",
    })
    local bindText = bindButton.Text
    bindText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    panel.bindText = bindText

    -- Compose with StyleButton's hover: after its OnLeave runs (which resets to the
    -- neutral rest), re-paint the green capturing border if we're still capturing.
    bindButton:HookScript("OnLeave", function(self)
        if panel.isCapturing then
            self:SetBackdropBorderColor(0.2, 0.8, 0.4, 1)
        end
    end)
    -- Register for all mouse buttons so we can capture them
    bindButton:RegisterForClicks("AnyDown")
    bindButton:SetScript("OnClick", function(self, button)
        if panel.isCapturing then
            -- Already capturing - treat this click as the binding
            CC:CaptureBinding("mouse", button)
        else
            -- Not capturing - start capture mode
            CC:StartBindingCapture()
        end
    end)
    bindButton:EnableMouseWheel(true)
    bindButton:SetScript("OnMouseWheel", function(self, delta)
        if panel.isCapturing then
            local scrollKey = delta > 0 and "SCROLLUP" or "SCROLLDOWN"
            CC:CaptureBinding("scroll", scrollKey)
        end
    end)
    panel.bindButton = bindButton
    
    -- Clear binding button
    local clearBindBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    clearBindBtn:SetPoint("LEFT", bindButton, "RIGHT", 6, 0)
    clearBindBtn:SetSize(60, 26)
    DF.GUI:StyleButton(clearBindBtn, {
        tone = "danger",
        text = L["Unbind"],
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close", size = 14 },
    })
    clearBindBtn:SetScript("OnClick", function()
        panel.pendingBinding.bindType = nil
        panel.pendingBinding.button = nil
        panel.pendingBinding.key = nil
        panel.pendingBinding.modifiers = ""
        panel.bindText:SetText(L["Click to bind..."])
        panel.bindText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end)
    
    -- Mac warning label (always created, only shown on Mac by default)
    local macWarning = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    macWarning:SetPoint("TOPLEFT", bindButton, "BOTTOMLEFT", 0, -2)
    macWarning:SetPoint("RIGHT", clearBindBtn, "RIGHT", 0, 0)
    macWarning:SetJustifyH("LEFT")
    macWarning:SetWordWrap(false)
    macWarning:SetText(("|c" .. DF.GUI:ToneHex("caution") .. L["Note"] .. ":|r ") .. L["Cmd + Left Click unavailable on Mac"])
    macWarning:SetTextColor(0.6, 0.6, 0.6)
    if IsMacClient and IsMacClient() then
        macWarning:Show()
    else
        macWarning:Hide()
    end
    panel.macWarning = macWarning
    
    -- Helper to create radio button
    local function CreateRadioButton(parent, text, yOffset, group)
        local radio = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
        -- Box + themed check from the shared styler (Binds keeps its green accent).
        DF.GUI:StyleCheckButton(radio, { accent = themeColor })

        local label = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        label:SetPoint("LEFT", radio, "RIGHT", 8, 0)
        label:SetText(text)
        label:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        
        radio.label = label
        radio.group = group
        
        return radio
    end
    
    -- Frames section (checkboxes)
    local framesLabel = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    framesLabel:SetPoint("TOPLEFT", 12, -125)
    framesLabel:SetText(L["Apply to Frames:"])
    framesLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Subtitle explaining what frames options are for
    local framesSubtitle = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    framesSubtitle:SetPoint("TOPLEFT", framesLabel, "BOTTOMLEFT", 0, -1)
    framesSubtitle:SetWidth(295)
    framesSubtitle:SetJustifyH("LEFT")
    framesSubtitle:SetWordWrap(true)
    framesSubtitle:SetText(L["Works when hovering frames. Action bars work when not hovering."])
    framesSubtitle:SetTextColor(0.5, 0.5, 0.5)
    panel.framesSubtitle = framesSubtitle
    
    -- Helper to create custom themed checkbox with tick mark
    local function CreateCheckbox(parent, text, desc)
        local cb = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
        cb.desc = desc
        -- Box + themed check from the shared styler; manualCheck because this
        -- factory shows/hides cb.check itself (no native checked state).
        cb.check = DF.GUI:StyleCheckButton(cb, { accent = themeColor, manualCheck = true })

        -- Text label
        local label = cb:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        label:SetPoint("LEFT", cb, "RIGHT", 8, 0)
        label:SetText(text)
        cb.text = label
        
        -- Internal checked state
        cb.isChecked = false
        
        -- Store external click handler
        cb.externalOnClick = nil
        
        -- Override SetScript to capture OnClick handlers
        local origSetScript = cb.SetScript
        cb.SetScript = function(self, scriptType, handler)
            if scriptType == "OnClick" then
                self.externalOnClick = handler
            else
                origSetScript(self, scriptType, handler)
            end
        end
        
        -- Override GetChecked
        cb.GetChecked = function(self)
            return self.isChecked
        end
        
        -- Override SetChecked to update visuals (show the green square only — the
        -- dark border stays put, matching the radio buttons + the addon standard).
        cb.SetChecked = function(self, checked)
            self.isChecked = checked
            self.check:SetShown(checked)
        end

        -- Internal click behavior
        origSetScript(cb, "OnClick", function(self)
            self.isChecked = not self.isChecked
            self.check:SetShown(self.isChecked)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            -- Call external handler if set
            if self.externalOnClick then
                self:externalOnClick()
            end
        end)

        -- Tooltip on hover (no border recolor — keep it consistent with radios)
        origSetScript(cb, "OnEnter", function(self)
            DF.GUI:ShowTooltip(self, {
                title = text,
                lines = self.desc and { self.desc } or nil,
            })
        end)
        origSetScript(cb, "OnLeave", function()
            DF.GUI:HideTooltip()
        end)
        
        return cb
    end
    
    -- DandersFrames checkbox
    local dfFramesCB = CreateCheckbox(panel, FRAME_INFO.dandersFrames.name, FRAME_INFO.dandersFrames.desc)
    dfFramesCB:SetPoint("TOPLEFT", 30, -168)
    dfFramesCB:SetScript("OnClick", function(self)
        panel.pendingBinding.frames = panel.pendingBinding.frames or {}
        panel.pendingBinding.frames.dandersFrames = self:GetChecked()
    end)
    panel.dfFramesCB = dfFramesCB
    
    -- Other Frames checkbox
    local otherFramesCB = CreateCheckbox(panel, FRAME_INFO.otherFrames.name, FRAME_INFO.otherFrames.desc)
    otherFramesCB:SetPoint("TOPLEFT", 30, -190)
    otherFramesCB:SetScript("OnClick", function(self)
        panel.pendingBinding.frames = panel.pendingBinding.frames or {}
        panel.pendingBinding.frames.otherFrames = self:GetChecked()
    end)
    panel.otherFramesCB = otherFramesCB
    
    -- Target Type section (moved up, was below Fallback)
    local targetLabel = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    targetLabel:SetPoint("TOPLEFT", 12, -218)
    targetLabel:SetText(L["Target Type:"])
    targetLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    panel.targetLabel = targetLabel
    
    local targetRadios = {}
    local targetOptions = {
        {key = "all", text = L["Any Target"], desc = TARGET_INFO.all.desc},
        {key = "friendly", text = L["Friendly Only"], desc = TARGET_INFO.friendly.desc},
        {key = "hostile", text = L["Hostile Only"], desc = TARGET_INFO.hostile.desc},
    }
    
    for i, opt in ipairs(targetOptions) do
        local radio = CreateRadioButton(panel, opt.text, 0, "target")
        radio:SetPoint("TOPLEFT", 30, -236 - ((i-1) * 20))
        radio.key = opt.key
        radio.desc = opt.desc
        
        radio:SetScript("OnClick", function(self)
            for _, r in ipairs(targetRadios) do
                r:SetChecked(r == self)
            end
            panel.pendingBinding.targetType = self.key
        end)
        
        radio:SetScript("OnEnter", function(self)
            DF.GUI:ShowTooltip(self, { title = opt.text, lines = { opt.desc } })
        end)
        radio:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)

        table.insert(targetRadios, radio)
    end
    panel.targetRadios = targetRadios
    
    -- Combat/Active section (moved up, was below Target Type)
    local combatLabel = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    combatLabel:SetPoint("TOPLEFT", 12, -302)
    combatLabel:SetText(L["Active:"])
    combatLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    panel.combatLabel = combatLabel
    
    local combatRadios = {}
    local combatOptions = {
        {key = "always", text = L["Always"], desc = COMBAT_INFO.always.desc},
        {key = "incombat", text = L["In Combat Only"], desc = COMBAT_INFO.incombat.desc},
        {key = "outofcombat", text = L["Out of Combat Only"], desc = COMBAT_INFO.outofcombat.desc},
    }
    
    for i, opt in ipairs(combatOptions) do
        local radio = CreateRadioButton(panel, opt.text, 0, "combat")
        radio:SetPoint("TOPLEFT", 30, -320 - ((i-1) * 20))
        radio.key = opt.key
        radio.desc = opt.desc
        
        radio:SetScript("OnClick", function(self)
            for _, r in ipairs(combatRadios) do
                r:SetChecked(r == self)
            end
            panel.pendingBinding.combat = self.key
        end)
        
        radio:SetScript("OnEnter", function(self)
            DF.GUI:ShowTooltip(self, { title = opt.text, lines = { opt.desc } })
        end)
        radio:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)

        table.insert(combatRadios, radio)
    end
    panel.combatRadios = combatRadios
    
    -- ============================================================
    -- ADVANCED COLLAPSIBLE SECTION
    -- ============================================================
    
    local COLLAPSED_HEIGHT = 502
    local EXPANDED_HEIGHT = 685
    
    -- Advanced header/toggle button
    local advancedToggle = CreateFrame("Button", nil, panel, "BackdropTemplate")
    advancedToggle:SetPoint("TOPLEFT", 12, -385)
    -- Chrome + hover (accent border/wash) from the shared styler; the chevron icon
    -- and "Advanced" label are owned by StyleButton (left-aligned, icon at 6px to
    -- match the prior layout). Collapse/expand OnClick + chevron rotation are wired
    -- below.
    DF.GUI:StyleButton(advancedToggle, {
        width = 296, height = 22,
        accent = CC.ACCENT,
        align = "left", leftPad = 6,
        text = L["Advanced"],
        font = "DFFontNormal",
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right",
            size = 12,
            color = C_TEXT_DIM,
        },
    })
    -- StyleButton's icon is the chevron; keep the old local name for the rotation
    -- handlers below (and the label colour dimmed to match the section-header look).
    local advancedArrow = advancedToggle.Icon
    advancedToggle.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    panel.advancedToggle = advancedToggle
    panel.advancedArrow = advancedArrow
    panel.advancedExpanded = false
    
    -- Advanced content container (hidden by default)
    local advancedContent = CreateFrame("Frame", nil, panel)
    advancedContent:SetPoint("TOPLEFT", advancedToggle, "BOTTOMLEFT", 0, -8)
    advancedContent:SetSize(296, 140)
    advancedContent:Hide()
    panel.advancedContent = advancedContent
    
    -- Fallback section (inside advanced content)
    local fallbackLabel = advancedContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    fallbackLabel:SetPoint("TOPLEFT", 0, 0)
    fallbackLabel:SetText(L["Targeting Fallback:"])
    fallbackLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    panel.fallbackLabel = fallbackLabel
    
    -- Subtitle explaining what fallback is for
    local fallbackSubtitle = advancedContent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    fallbackSubtitle:SetPoint("TOPLEFT", fallbackLabel, "BOTTOMLEFT", 0, -1)
    fallbackSubtitle:SetWidth(280)
    fallbackSubtitle:SetJustifyH("LEFT")
    fallbackSubtitle:SetWordWrap(true)
    fallbackSubtitle:SetText(format(L["For nameplates & world units. %sDoes not work with action bar binds.%s"], "|c" .. DF.GUI:ToneHex("caution"), "|r"))
    fallbackSubtitle:SetTextColor(0.5, 0.5, 0.5)
    panel.fallbackSubtitle = fallbackSubtitle
    
    -- Mouseover checkbox
    local mouseoverCB = CreateCheckbox(advancedContent, FALLBACK_INFO.mouseover.name, FALLBACK_INFO.mouseover.desc)
    mouseoverCB:SetPoint("TOPLEFT", 18, -38)
    mouseoverCB:SetScript("OnClick", function(self)
        panel.pendingBinding.fallback = panel.pendingBinding.fallback or {}
        panel.pendingBinding.fallback.mouseover = self:GetChecked()
    end)
    panel.mouseoverCB = mouseoverCB
    
    -- Target checkbox
    local targetFallbackCB = CreateCheckbox(advancedContent, FALLBACK_INFO.target.name, FALLBACK_INFO.target.desc)
    targetFallbackCB:SetPoint("TOPLEFT", 18, -60)
    targetFallbackCB:SetScript("OnClick", function(self)
        panel.pendingBinding.fallback = panel.pendingBinding.fallback or {}
        panel.pendingBinding.fallback.target = self:GetChecked()
    end)
    panel.targetFallbackCB = targetFallbackCB
    
    -- Self checkbox
    local selfCB = CreateCheckbox(advancedContent, FALLBACK_INFO.selfCast.name, FALLBACK_INFO.selfCast.desc)
    selfCB:SetPoint("TOPLEFT", 18, -82)
    selfCB:SetScript("OnClick", function(self)
        panel.pendingBinding.fallback = panel.pendingBinding.fallback or {}
        panel.pendingBinding.fallback.selfCast = self:GetChecked()
    end)
    panel.selfCB = selfCB

    -- Macro Options section header
    local macroOptionsLabel = advancedContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    macroOptionsLabel:SetPoint("TOPLEFT", 0, -108)
    macroOptionsLabel:SetText(L["Macro Options:"])
    macroOptionsLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    panel.macroOptionsLabel = macroOptionsLabel

    -- Cancel Targeting checkbox (stopSpellTarget)
    local stopSpellTargetCB = CreateCheckbox(advancedContent, FALLBACK_INFO.stopSpellTarget.name, FALLBACK_INFO.stopSpellTarget.desc)
    stopSpellTargetCB:SetPoint("TOPLEFT", 18, -128)
    stopSpellTargetCB:SetScript("OnClick", function(self)
        panel.pendingBinding.fallback = panel.pendingBinding.fallback or {}
        panel.pendingBinding.fallback.stopSpellTarget = self:GetChecked()
    end)
    panel.stopSpellTargetCB = stopSpellTargetCB

    -- Target on cast checkbox (per-binding override of the global setting)
    local targetOnCastCB = CreateCheckbox(advancedContent, L["Target on cast"], L["Also make this unit your target when you click-cast on it. Overrides the global 'Target unit when click-casting' setting."])
    targetOnCastCB:SetPoint("TOPLEFT", 18, -150)
    targetOnCastCB:SetScript("OnClick", function(self)
        panel.pendingBinding.targetOnCast = self:GetChecked()
    end)
    panel.targetOnCastCB = targetOnCastCB

    -- Priority slider (inside advanced content)
    local priorityLabel = advancedContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    priorityLabel:SetPoint("TOPLEFT", 0, -158)
    priorityLabel:SetText(L["Priority:"])
    priorityLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    panel.priorityLabel = priorityLabel

    -- Shared slider builder. The stored field (panel.pendingBinding.priority) is
    -- written 1:1 via customGet/customSet and shown directly in the input box.
    -- Direction: HIGHER number = higher priority (10 wins over 1), matching every
    -- other slider (right = more). Thumb runs left = 1 (Low) .. right = 10 (High).
    -- A lazy per-profile migration (CC:MigratePrioritiesLazy) remaps older saved
    -- values on first access, and the resolution comparators were flipped, so
    -- existing bindings resolve the same.
    local prioritySlider = DF.GUI:CreateSlider(
        advancedContent,            -- parent
        "",                         -- label (priorityLabel handles the caption)
        1,                          -- minVal
        10,                         -- maxVal
        1,                          -- step
        nil,                        -- dbTable (custom get/set used instead)
        nil,                        -- dbKey
        nil,                        -- callback
        false,                      -- lightweightUpdate
        false,                      -- usePreviewMode
        function()                  -- customGet: return stored priority
            -- Guard: the panel is built once (cached) and CreateSlider reads its
            -- initial value here BEFORE ShowEditBindingPanel assigns pendingBinding.
            return (panel.pendingBinding and panel.pendingBinding.priority) or 5
        end,
        function(v)                 -- customSet: store priority unchanged
            if panel.pendingBinding then panel.pendingBinding.priority = v end
        end,
        CC.ACCENT                   -- accentColor (ClickCasting green)
    )
    prioritySlider:SetPoint("TOPLEFT", 68, -155)

    -- Direction note (standard GUI label style). The slider's container is 50px
    -- tall (its bottom sits near the Delete/Cancel/Save row), so the note is placed
    -- in the gap BELOW the visible bar — anchored ~28px down from the slider top and
    -- shifted left to x=0 to sit under the "Priority:" caption. Anchored to the
    -- slider so it tracks the macro/spell repositioning; the CreateLabel frame has
    -- no background, so its lower extent over the button row is invisible.
    local priNote = DF.GUI:CreateLabel(advancedContent, L["Higher priority wins"], 248)
    priNote:SetPoint("TOPLEFT", prioritySlider, "TOPLEFT", -68, -28)

    panel.prioritySlider = prioritySlider
    
    -- ============================================================
    -- GLOBAL KEYBIND SECTION (for macros/items only, positioned above Active)
    -- ============================================================
    
    -- Global Keybind heading
    local globalBindLabel = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    globalBindLabel:SetPoint("TOPLEFT", 12, -302)  -- Will be repositioned dynamically
    globalBindLabel:SetText(L["Global Keybind:"])
    globalBindLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    globalBindLabel:Hide()
    panel.globalBindLabel = globalBindLabel
    
    -- Description for Global Keybind (below heading)
    local globalBindDesc = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    globalBindDesc:SetPoint("TOPLEFT", 12, -318)  -- Will be repositioned dynamically
    globalBindDesc:SetWidth(280)
    globalBindDesc:SetJustifyH("LEFT")
    globalBindDesc:SetWordWrap(true)
    globalBindDesc:SetText(L["For items/macros that need @cursor, @mouseover, etc. Consumes the keybind and prevents action bar use."])
    globalBindDesc:SetTextColor(0.5, 0.5, 0.5)
    globalBindDesc:Hide()
    panel.globalBindDesc = globalBindDesc
    
    -- Global Keybind checkbox (below description)
    local globalBindCB = CreateCheckbox(panel, L["Enable"], L["Makes this binding work everywhere, consuming the keybind."])
    globalBindCB:SetPoint("TOPLEFT", 30, -350)  -- Will be repositioned dynamically
    globalBindCB:SetScript("OnClick", function(self)
        panel.pendingBinding.useGlobalBind = self:GetChecked()
    end)
    globalBindCB:Hide()  -- Hidden by default, shown only for macros/items
    panel.globalBindCB = globalBindCB
    
    -- Toggle function for Advanced section
    local function ToggleAdvanced()
        panel.advancedExpanded = not panel.advancedExpanded
        
        -- Only macros use the compact heights (items now use the spell layout
        -- because they expose the targeting fallback section).
        local isMacroOnly = panel.pendingBinding and
            (panel.pendingBinding.actionType == CC.ACTION_TYPES.MACRO or
             panel.pendingBinding.macroId)

        local collapsedHeight = isMacroOnly and 475 or COLLAPSED_HEIGHT
        local expandedHeight = isMacroOnly and 540 or EXPANDED_HEIGHT
        
        if panel.advancedExpanded then
            advancedArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            advancedContent:Show()
            panel:SetHeight(expandedHeight)
        else
            advancedArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            advancedContent:Hide()
            panel:SetHeight(collapsedHeight)
        end
    end
    
    advancedToggle:SetScript("OnClick", ToggleAdvanced)
    panel.ToggleAdvanced = ToggleAdvanced
    
    -- Start collapsed
    panel:SetHeight(COLLAPSED_HEIGHT)
    
    -- Bottom buttons
    local saveBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    saveBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    DF.GUI:StyleButton(saveBtn, {
        width = 90, height = 28, tone = "success", accent = CC.ACCENT,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\save", size = 18 },
        text = L["Save"],
    })
    saveBtn:SetScript("OnClick", function()
        CC:SaveEditBindingPanel()
    end)

    local cancelBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    cancelBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
    DF.GUI:StyleButton(cancelBtn, { width = 90, height = 28, text = L["Cancel"], accent = CC.ACCENT })
    cancelBtn:SetScript("OnClick", function()
        CC:HideEditBindingPanel()
    end)

    -- Delete button (only shown when editing existing binding)
    local deleteBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    deleteBtn:SetPoint("BOTTOMLEFT", 12, 12)
    DF.GUI:StyleButton(deleteBtn, {
        width = 80, height = 28,
        tone = "danger",
        text = L["Delete"],
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\delete", size = 18 },
    })
    deleteBtn:SetScript("OnClick", function()
        CC:DeleteFromEditBindingPanel()
    end)
    panel.deleteBtn = deleteBtn
    
    -- Keyboard input capture for binding button
    panel:SetScript("OnKeyDown", function(self, key)
        if not self.isCapturing then return end
        
        if key == "ESCAPE" then
            CC:StopBindingCapture()
            return
        end
        
        -- Check if it's a modifier key - these shouldn't be captured as the main key
        if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL" or key == "LALT" or key == "RALT" or key == "LMETA" or key == "RMETA" then
            return
        end
        
        -- Accept any key that WoW reports - this supports international keyboards
        -- Keys like ^ on German keyboards, ñ on Spanish, etc.
        if key and key ~= "" then
            CC:CaptureBinding("key", key)
        end
    end)
    
    panel:SetScript("OnMouseDown", function(self, button)
        if not self.isCapturing then return end
        
        if button == "LeftButton" or button == "RightButton" or button == "MiddleButton" or button:match("^Button%d+$") then
            CC:CaptureBinding("mouse", button)
        end
    end)
    
    panel:SetScript("OnMouseWheel", function(self, delta)
        if not self.isCapturing then return end
        
        local scrollKey = delta > 0 and "SCROLLUP" or "SCROLLDOWN"
        CC:CaptureBinding("scroll", scrollKey)
    end)
    
    self.editBindingPanel = panel
end

function CC:StartBindingCapture()
    local panel = self.editBindingPanel
    if not panel then return end
    
    panel.isCapturing = true
    panel:EnableKeyboard(true)
    panel:EnableMouseWheel(true)
    panel.bindButton:SetBackdropBorderColor(0.2, 0.8, 0.4, 1)
    panel.bindText:SetText(L["Press key/click/scroll..."])
    panel.bindText:SetTextColor(0.2, 0.8, 0.4)
    
    -- Update modifier display during capture
    panel.captureUpdateTimer = C_Timer.NewTicker(0.05, function()
        if not panel.isCapturing then return end
        local mods = ""
        if IsShiftKeyDown() then mods = mods .. "Shift + " end
        if IsControlKeyDown() then mods = mods .. "Ctrl + " end
        if IsAltKeyDown() then mods = mods .. "Alt + " end
        if IsMetaKeyDown() then mods = mods .. "Cmd + " end
        if mods ~= "" then
            panel.bindText:SetText(mods .. "...")
        else
            panel.bindText:SetText(L["Press key/click/scroll..."])
        end
    end)
end

function CC:StopBindingCapture()
    local panel = self.editBindingPanel
    if not panel then return end
    
    panel.isCapturing = false
    panel:EnableKeyboard(false)
    panel.bindButton:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    
    if panel.captureUpdateTimer then
        panel.captureUpdateTimer:Cancel()
        panel.captureUpdateTimer = nil
    end
    
    -- Restore binding text
    CC:UpdateBindingButtonText()
end

function CC:CaptureBinding(bindType, key)
    local panel = self.editBindingPanel
    if not panel then return end
    
    -- Build modifier string
    local mods = ""
    if IsShiftKeyDown() then mods = mods .. "shift-" end
    if IsControlKeyDown() then mods = mods .. "ctrl-" end
    if IsAltKeyDown() then mods = mods .. "alt-" end
    if IsMetaKeyDown() then mods = mods .. "meta-" end
    
    panel.pendingBinding.bindType = bindType
    panel.pendingBinding.modifiers = mods
    
    if bindType == "mouse" then
        panel.pendingBinding.button = key
        panel.pendingBinding.key = nil
        
        -- Warn Mac users about Command+Left Click limitation (right click works fine)
        if mods:find("meta") and key == "LeftButton" then
            CC:ShowMacMetaClickWarning()
        end
    else
        panel.pendingBinding.key = key
        panel.pendingBinding.button = nil
    end
    
    CC:StopBindingCapture()
end

-- Show warning about Mac Command+Left Click not working
function CC:ShowMacMetaClickWarning()
    StaticPopupDialogs["DF_MAC_META_CLICK_WARNING"] = {
        text = "|c" .. DF.GUI:ToneHex("caution") .. L["Mac Limitation"] .. "|r\n\n" ..
               L["Command + Left Click bindings do not work on macOS. "] ..
               L["This is a World of Warcraft client limitation, not an addon bug."] .. "\n\n" ..
               L["The binding will be saved, but it will not trigger in-game."] .. "\n\n" ..
               "|c" .. DF.GUI:ToneHex("success") .. L["Recommendation:"] .. "|r " .. L["Use "] .. "|cffffffff" .. L["Option (Alt)"] .. "|r " .. L["or "] .. "|cffffffff" .. L["Control"] .. "|r " .. L["instead of Command for left click modifiers."],
        button1 = L["OK"],
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    ShowPopupOnTop("DF_MAC_META_CLICK_WARNING")
end

function CC:UpdateBindingButtonText()
    local panel = self.editBindingPanel
    if not panel then return end
    
    local binding = panel.pendingBinding
    if binding.bindType and (binding.button or binding.key) then
        local text = CC:GetBindingKeyText(binding)
        panel.bindText:SetText(text)
        panel.bindText:SetTextColor(0.9, 0.9, 0.9)
    else
        panel.bindText:SetText(L["Click to bind..."])
        panel.bindText:SetTextColor(0.5, 0.5, 0.5)
    end
end

function CC:ShowEditBindingPanel(spellData, existingBinding, existingIndex)
    if not self.editBindingPanel then
        self:CreateEditBindingPanel()
    end
    
    local panel = self.editBindingPanel
    
    -- Store context
    panel.spellData = spellData
    panel.existingIndex = existingIndex
    panel.isEditing = existingIndex ~= nil
    
    -- Initialize pending binding data
    if existingBinding then
        panel.pendingBinding = CopyTable(existingBinding)
        -- Ensure frames and fallback exist
        panel.pendingBinding.frames = panel.pendingBinding.frames or { dandersFrames = true, otherFrames = true }
        panel.pendingBinding.fallback = panel.pendingBinding.fallback or { mouseover = false, target = false, selfCast = false }
    else
        panel.pendingBinding = {
            enabled = true,
            bindType = nil,
            button = nil,
            key = nil,
            modifiers = "",
            frames = { dandersFrames = true, otherFrames = true },
            fallback = { mouseover = false, target = false, selfCast = false },
            combat = DEFAULT_BINDING_COMBAT,
            actionType = spellData.actionType or self.ACTION_TYPES.SPELL,
            spellId = spellData.spellId,
            spellName = spellData.spellName or spellData.name,
            priority = 5,  -- Default priority (10=highest, 1=lowest)
        }
        
        if spellData.isMacro then
            panel.pendingBinding.actionType = self.ACTION_TYPES.MACRO
            panel.pendingBinding.macroId = spellData.macroId
            panel.pendingBinding.macroName = spellData.name
        elseif spellData.isItem then
            panel.pendingBinding.actionType = self.ACTION_TYPES.ITEM
            panel.pendingBinding.itemType = spellData.itemType
            if spellData.itemType == "slot" then
                panel.pendingBinding.itemSlot = spellData.itemSlot
                panel.pendingBinding.itemName = spellData.slotName or spellData.name
            else
                panel.pendingBinding.itemId = spellData.itemId
                panel.pendingBinding.itemName = spellData.name
            end
        end
    end
    
    -- Update title
    if panel.isEditing then
        panel.title:SetText(L["Edit Binding"])
    else
        panel.title:SetText(L["New Binding"])
    end
    
    -- Update spell info - handle icons for spells, macros, items, and actions
    local iconTexture = spellData.icon
    if not iconTexture and existingBinding then
        local actionType = existingBinding.actionType
        if actionType == "target" then
            iconTexture = "Interface\\CURSOR\\Crosshairs"
        elseif actionType == "menu" then
            iconTexture = "Interface\\Buttons\\UI-GuildButton-OfficerNote-Up"
        elseif actionType == "focus" then
            iconTexture = "Interface\\Icons\\Ability_Hunter_MasterMarksman"
        elseif actionType == "assist" then
            iconTexture = "Interface\\Icons\\Ability_Hunter_SniperShot"
        elseif actionType == CC.ACTION_TYPES.ITEM then
            -- Item binding
            if existingBinding.itemType == "slot" and existingBinding.itemSlot then
                local itemInfo = CC:GetSlotItemInfo(existingBinding.itemSlot)
                if itemInfo and itemInfo.icon then
                    iconTexture = itemInfo.icon
                end
            elseif existingBinding.itemId then
                local itemInfo = CC:GetItemInfoById(existingBinding.itemId)
                if itemInfo and itemInfo.icon then
                    iconTexture = itemInfo.icon
                end
            end
        elseif existingBinding.spellId then
            iconTexture = C_Spell.GetSpellTexture(existingBinding.spellId)
        elseif existingBinding.macroId then
            -- Look up macro icon - try auto-detect first
            local macro = CC:GetMacroById(existingBinding.macroId)
            if macro then
                iconTexture = CC:GetIconFromMacroBody(macro.body)
                if not iconTexture and macro.icon and type(macro.icon) == "number" and macro.icon > 0 then
                    iconTexture = macro.icon
                end
            end
        end
    end
    if not iconTexture then
        iconTexture = "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    panel.icon:SetTexture(iconTexture)
    
    -- Get display name (shows current override for talent-modified spells)
    local displayName = spellData.name or spellData.spellName
    if spellData.spellId and not spellData.isMacro and not spellData.isItem then
        displayName = GetSpellDisplayInfo(spellData.spellId, displayName) or displayName
    elseif existingBinding and existingBinding.spellId then
        displayName = GetSpellDisplayInfo(existingBinding.spellId, existingBinding.spellName) or displayName
    end
    panel.spellName:SetText(displayName or L["Unknown"])
    
    -- Update binding button
    CC:UpdateBindingButtonText()
    
    -- Check if this is a macro or item binding (macros handle their own targeting)
    local actionType = panel.pendingBinding.actionType
    local isMacro = (actionType == CC.ACTION_TYPES.MACRO)
    local isItem = (actionType == CC.ACTION_TYPES.ITEM)
    -- Only macros hide the targeting section. Items use spell-style fallbacks
    -- (mouseover / target / self) because /use can take @mouseover etc.
    local hideTargeting = isMacro
    -- Target / menu binds have no meaningful Advanced options (fallbacks, macro
    -- options, global bind, priority are all spell/macro concepts), so the whole
    -- Advanced section is hidden for them further below.
    local isMenuOrTarget = (actionType == CC.ACTION_TYPES.TARGET or actionType == CC.ACTION_TYPES.MENU)
    
    -- Update frames checkboxes (always shown)
    local frames = panel.pendingBinding.frames or { dandersFrames = true, otherFrames = true }
    panel.dfFramesCB:SetChecked(frames.dandersFrames)
    panel.otherFramesCB:SetChecked(frames.otherFrames)
    
    -- Check if this binding has advanced options set (should auto-expand)
    local fallback = panel.pendingBinding.fallback or { mouseover = false, target = false, selfCast = false }
    local hasAdvancedOptions = fallback.mouseover or fallback.target or fallback.selfCast or fallback.stopSpellTarget
        or panel.pendingBinding.targetOnCast ~= nil
    local currentPriority = panel.pendingBinding.priority or 5
    if currentPriority ~= 5 then
        hasAdvancedOptions = true
    end
    
    -- Show/hide and initialize Advanced section based on macro/item status
    -- Macros and items handle their own targeting logic, so hide targeting options for them
    -- BUT still show Advanced section for priority control and global bind option
    if hideTargeting then
        -- Show Advanced toggle for macros/items (just with fallback hidden)
        if panel.advancedToggle then
            panel.advancedToggle:Show()
        end
        
        -- Hide fallback section within Advanced (macros handle their own targeting)
        if panel.fallbackLabel then panel.fallbackLabel:Hide() end
        if panel.fallbackSubtitle then panel.fallbackSubtitle:Hide() end
        if panel.mouseoverCB then panel.mouseoverCB:Hide() end
        if panel.targetFallbackCB then panel.targetFallbackCB:Hide() end
        if panel.selfCB then panel.selfCB:Hide() end
        if panel.macroOptionsLabel then panel.macroOptionsLabel:Hide() end
        if panel.stopSpellTargetCB then panel.stopSpellTargetCB:Hide() end
        if panel.targetOnCastCB then panel.targetOnCastCB:Hide() end
        
        -- Show Global Keybind section for macros/items (above Active section)
        -- Layout: Global Keybind: (heading) -> description -> checkbox
        if panel.globalBindLabel then
            panel.globalBindLabel:Show()
            panel.globalBindLabel:ClearAllPoints()
            panel.globalBindLabel:SetPoint("TOPLEFT", 12, -218)  -- Same Y as where Active would be for spells
        end
        if panel.globalBindDesc then
            panel.globalBindDesc:Show()
            panel.globalBindDesc:ClearAllPoints()
            panel.globalBindDesc:SetPoint("TOPLEFT", 12, -234)  -- Below heading
        end
        if panel.globalBindCB then
            panel.globalBindCB:Show()
            panel.globalBindCB:SetChecked(panel.pendingBinding.useGlobalBind == true)
            panel.globalBindCB:ClearAllPoints()
            panel.globalBindCB:SetPoint("TOPLEFT", 30, -270)  -- Below description
        end
        
        -- Move priority slider up since fallback is hidden
        if panel.priorityLabel then
            panel.priorityLabel:ClearAllPoints()
            panel.priorityLabel:SetPoint("TOPLEFT", panel.advancedContent, "TOPLEFT", 0, -4)
        end
        if panel.prioritySlider then
            panel.prioritySlider:ClearAllPoints()
            panel.prioritySlider:SetPoint("TOPLEFT", panel.advancedContent, "TOPLEFT", 68, -1)
        end
        
        -- Auto-expand Advanced if binding has non-default priority
        local currentPriority = panel.pendingBinding.priority or DEFAULT_PRIORITY
        if currentPriority ~= DEFAULT_PRIORITY and not panel.advancedExpanded then
            panel.advancedExpanded = true
            if panel.advancedArrow then
                panel.advancedArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            end
            if panel.advancedContent then
                panel.advancedContent:Show()
            end
        end
    else
        -- Show Advanced toggle for spells
        if panel.advancedToggle then
            panel.advancedToggle:Show()
        end
        
        -- Show fallback section for spells
        if panel.fallbackLabel then panel.fallbackLabel:Show() end
        if panel.fallbackSubtitle then panel.fallbackSubtitle:Show() end
        if panel.mouseoverCB then panel.mouseoverCB:Show() end
        if panel.targetFallbackCB then panel.targetFallbackCB:Show() end
        if panel.selfCB then panel.selfCB:Show() end
        if panel.macroOptionsLabel then panel.macroOptionsLabel:Show() end
        if panel.stopSpellTargetCB then panel.stopSpellTargetCB:Show() end
        if panel.targetOnCastCB then panel.targetOnCastCB:Show() end
        
        -- Hide Global Keybind section for spells (they use fallback options instead)
        if panel.globalBindLabel then
            panel.globalBindLabel:Hide()
        end
        if panel.globalBindCB then
            panel.globalBindCB:Hide()
        end
        if panel.globalBindDesc then
            panel.globalBindDesc:Hide()
        end
        
        -- Reset priority slider position for spells (shifted down for the
        -- Target on cast row added to Macro Options)
        if panel.priorityLabel then
            panel.priorityLabel:ClearAllPoints()
            panel.priorityLabel:SetPoint("TOPLEFT", panel.advancedContent, "TOPLEFT", 0, -182)
        end
        if panel.prioritySlider then
            panel.prioritySlider:ClearAllPoints()
            panel.prioritySlider:SetPoint("TOPLEFT", panel.advancedContent, "TOPLEFT", 68, -179)
        end
        
        -- Auto-expand if binding has advanced options
        if hasAdvancedOptions and not panel.advancedExpanded then
            panel.advancedExpanded = true
            if panel.advancedArrow then
                panel.advancedArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            end
            if panel.advancedContent then
                panel.advancedContent:Show()
            end
        elseif not hasAdvancedOptions and panel.advancedExpanded then
            -- Collapse if no advanced options
            panel.advancedExpanded = false
            if panel.advancedArrow then
                panel.advancedArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            end
            if panel.advancedContent then
                panel.advancedContent:Hide()
            end
        end
    end
    
    -- Hide target type for macros/items (they use their own [help]/[harm] conditions)
    panel.targetLabel:SetShown(not hideTargeting)
    for _, radio in ipairs(panel.targetRadios) do
        radio:SetShown(not hideTargeting)
        if radio.label then
            radio.label:SetShown(not hideTargeting)
        end
    end
    
    -- Reposition combat/active section and advanced toggle based on whether target type is shown
    -- Target Type takes up about 80px (-218 to -296), so when hidden, move things up
    if hideTargeting then
        -- For macros/items: Global Keybind section goes where Target Type was
        -- Layout: Global Keybind (-218) -> Active (-295) -> Advanced (-380)
        
        -- Move Active section down to make room for Global Keybind section above it
        panel.combatLabel:ClearAllPoints()
        panel.combatLabel:SetPoint("TOPLEFT", 12, -295)
        
        -- Move combat radios down
        for i, radio in ipairs(panel.combatRadios) do
            radio:ClearAllPoints()
            radio:SetPoint("TOPLEFT", 30, -313 - ((i-1) * 20))
        end
        
        -- Move advanced toggle below Active section
        panel.advancedToggle:ClearAllPoints()
        panel.advancedToggle:SetPoint("TOPLEFT", 12, -380)
    else
        -- Restore normal positions for spells
        panel.combatLabel:ClearAllPoints()
        panel.combatLabel:SetPoint("TOPLEFT", 12, -302)
        
        for i, radio in ipairs(panel.combatRadios) do
            radio:ClearAllPoints()
            radio:SetPoint("TOPLEFT", 30, -320 - ((i-1) * 20))
        end
        
        panel.advancedToggle:ClearAllPoints()
        panel.advancedToggle:SetPoint("TOPLEFT", 12, -385)
    end

    -- Target / menu binds: hide the entire Advanced section. Its options do
    -- nothing for these actions, so showing them only causes confusion. The Save/
    -- Cancel/Delete buttons are anchored to the panel bottom, so the shorter
    -- height below keeps them tucked under the visible content.
    if isMenuOrTarget then
        panel.advancedExpanded = false
        if panel.advancedToggle then panel.advancedToggle:Hide() end
        if panel.advancedContent then panel.advancedContent:Hide() end
    end

    -- Adjust panel height based on macro/item vs spell, and Advanced expanded state
    local SPELL_COLLAPSED_HEIGHT = 502
    local SPELL_EXPANDED_HEIGHT = 685
    local MACRO_COLLAPSED_HEIGHT = 475  -- With Global Keybind section above Active
    local MACRO_EXPANDED_HEIGHT = 540   -- With Advanced expanded (just priority slider)
    local SPECIAL_COLLAPSED_HEIGHT = 450 -- Target/menu: target type + combat, no Advanced section

    if hideTargeting then
        -- For macros/items: no target type section
        if panel.advancedExpanded then
            panel:SetHeight(MACRO_EXPANDED_HEIGHT)
        else
            panel:SetHeight(MACRO_COLLAPSED_HEIGHT)
        end
    elseif isMenuOrTarget then
        -- Target/menu: Advanced section hidden entirely
        panel:SetHeight(SPECIAL_COLLAPSED_HEIGHT)
    elseif panel.advancedExpanded then
        panel:SetHeight(SPELL_EXPANDED_HEIGHT)
    else
        panel:SetHeight(SPELL_COLLAPSED_HEIGHT)
    end
    
    -- Update priority slider. The slider's internal value equals the stored
    -- priority directly (1 = Low .. 10 = High; higher wins); the builder's input
    -- box and fill update off this value.
    panel.prioritySlider.slider:SetValue(currentPriority)
    
    -- Update fallback checkboxes (only if not a macro)
    if not isMacro then
        panel.mouseoverCB:SetChecked(fallback.mouseover == true)
        panel.targetFallbackCB:SetChecked(fallback.target == true)
        panel.selfCB:SetChecked(fallback.selfCast == true)
        panel.stopSpellTargetCB:SetChecked(fallback.stopSpellTarget == true)
        -- Show the effective state (global default unless this binding overrides it).
        -- Clicking writes an explicit override; leaving it untouched keeps inheriting.
        panel.targetOnCastCB:SetChecked(CC:GetEffectiveTargetOnCast(panel.pendingBinding))
    end
    
    -- Update target type radios (only if not a macro)
    if not isMacro then
        local currentTargetType = panel.pendingBinding.targetType or DEFAULT_TARGET_TYPE
        for _, radio in ipairs(panel.targetRadios) do
            radio:SetChecked(radio.key == currentTargetType)
        end
    end
    
    -- Update combat radios
    local currentCombat = panel.pendingBinding.combat or DEFAULT_BINDING_COMBAT
    for _, radio in ipairs(panel.combatRadios) do
        radio:SetChecked(radio.key == currentCombat)
    end
    
    -- Show/hide delete button based on editing mode
    panel.deleteBtn:SetShown(panel.isEditing)
    
    -- Position centered on click cast UI
    panel:ClearAllPoints()
    if self.clickCastUIFrame then
        panel:SetPoint("CENTER", self.clickCastUIFrame, "CENTER", 0, 0)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    
    panel:Show()
    panel:Raise()
end

function CC:HideEditBindingPanel()
    if self.editBindingPanel then
        CC:StopBindingCapture()
        self.editBindingPanel:Hide()
        self.editBindingPanel.spellData = nil
        self.editBindingPanel.existingIndex = nil
        self.editBindingPanel.pendingBinding = nil
    end
end

function CC:SaveEditBindingPanel()
    local panel = self.editBindingPanel
    if not panel or not panel.pendingBinding then return end
    
    local binding = panel.pendingBinding
    
    -- Validate that we have a binding key
    if not binding.bindType or (not binding.button and not binding.key) then
        print("|cffff6666DandersFrames:|r " .. L["Please set a binding key first."])
        return
    end
    
    -- Multiple bindings on same key allowed for fallback functionality
    self:FinalizeSaveBinding()
end

function CC:FinalizeSaveBinding()
    local panel = self.editBindingPanel
    if not panel or not panel.pendingBinding then return end
    
    local binding = panel.pendingBinding
    
    -- Macros handle their own targeting, so force no fallbacks for macro bindings
    if binding.actionType == self.ACTION_TYPES.MACRO or binding.actionType == "macro" then
        binding.fallback = {
            mouseover = false,
            target = false,
            selfCast = false,
        }
    end
    
    -- Check for duplicate binding (exclude self when editing)
    local excludeIndex = panel.isEditing and panel.existingIndex or nil
    local duplicateIndex = self:FindDuplicateBinding(binding, excludeIndex)
    if duplicateIndex then
        print("|cffff9900DandersFrames:|r " .. L["That binding already exists."])
        return
    end

    -- Check for key conflicts (same key combo, different action)
    local conflicts = self:FindKeyConflicts(binding, excludeIndex)
    if #conflicts > 0 then
        -- Build conflict description
        local conflictDesc = ""
        for i, conflict in ipairs(conflicts) do
            local existingBinding = conflict.binding
            local actionName = self:GetBindingActionText(existingBinding) or "Unknown"
            if i > 1 then conflictDesc = conflictDesc .. "\n" end
            conflictDesc = conflictDesc .. "• " .. actionName
            if i >= 3 and #conflicts > 3 then
                conflictDesc = conflictDesc .. "\n• ... and " .. (#conflicts - 3) .. " more"
                break
            end
        end
        
        local keyText = self:GetBindingKeyText(binding)
        
        -- Show warning popup
        StaticPopupDialogs["DF_KEY_CONFLICT_WARNING"] = {
            text = "|c" .. DF.GUI:ToneHex("danger") .. L["Warning:"] .. "|r " .. keyText .. " " .. L["is already bound to:"] .. "\n\n" .. conflictDesc .. "\n\n" .. L["Multiple bindings on the same key may not work as expected. Save anyway?"],
            button1 = L["Save Anyway"],
            button2 = L["Cancel"],
            OnAccept = function()
                CC:CommitBindingSave()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        ShowPopupOnTop("DF_KEY_CONFLICT_WARNING")
        return
    end
    
    -- No conflicts, save directly
    self:CommitBindingSave()
end

-- Actually commit the binding save (called after conflict check passes or user confirms)
function CC:CommitBindingSave()
    local panel = self.editBindingPanel
    if not panel or not panel.pendingBinding then return end
    
    local binding = panel.pendingBinding
    
    if panel.isEditing then
        -- Update existing binding
        self.db.bindings[panel.existingIndex] = binding
    else
        -- Add new binding
        table.insert(self.db.bindings, binding)
    end
    
    self:HideEditBindingPanel()
    self:UpdateBlizzardFrameRegistration()
    self:ApplyBindings()
    self:RefreshActiveBindings()
    self:RefreshSpellGrid(true)  -- Skip scroll reset to maintain position
end

function CC:DeleteFromEditBindingPanel()
    local panel = self.editBindingPanel
    if not panel or not panel.isEditing then return end
    
    local binding = self.db.bindings[panel.existingIndex]
    if not binding then return end
    
    StaticPopupDialogs["DF_EDITPANEL_CONFIRM_DELETE"] = {
        text = format(L["Delete binding for %s?"], self:GetBindingKeyText(binding)),
        button1 = L["Yes"],
        button2 = L["No"],
        OnAccept = function()
            table.remove(CC.db.bindings, panel.existingIndex)
            CC:HideEditBindingPanel()
            CC:UpdateBlizzardFrameRegistration()
            CC:ApplyBindings()
            CC:RefreshActiveBindings()
            CC:RefreshSpellGrid(true)  -- Skip scroll reset to maintain position
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    ShowPopupOnTop("DF_EDITPANEL_CONFIRM_DELETE")
end

-- Process a keybind from the quick bind popup
function CC:ProcessKeybind(bindType, key)
    if not self.pendingSpellData then return end
    
    local spellData = self.pendingSpellData
    
    -- Build modifier string
    local mods = ""
    if IsShiftKeyDown() then mods = mods .. "shift-" end
    if IsControlKeyDown() then mods = mods .. "ctrl-" end
    if IsAltKeyDown() then mods = mods .. "alt-" end
    if IsMetaKeyDown() then mods = mods .. "meta-" end
    
    -- Use default scope and combat settings for quick bind
    local defaultScope = DEFAULT_BINDING_SCOPE  -- "blizzard"
    local defaultCombat = DEFAULT_BINDING_COMBAT  -- "always"
    
    -- Build the new binding with full defaults
    local newBinding = {
        enabled = true,
        bindType = bindType,
        modifiers = mods,
        scope = defaultScope,
        combat = defaultCombat,
        priority = 5,  -- Default priority (10=highest, 1=lowest)
        -- Default to all frames
        frames = {
            dandersFrames = true,
            otherFrames = true,
        },
        -- Default fallbacks: all off (opt-in)
        fallback = {
            mouseover = false,
            target = false,
            selfCast = false,
        },
        -- Default to any target
        targetType = "all",
    }
    
    if bindType == "mouse" then
        newBinding.button = key
    else
        newBinding.key = key
    end
    
    -- Set action type based on what we're binding
    if spellData.isMacro then
        -- Macro binding
        newBinding.actionType = self.ACTION_TYPES.MACRO
        newBinding.macroId = spellData.macroId
        newBinding.macroName = spellData.name
        -- Macros handle their own targeting, so no fallbacks
        newBinding.fallback = {
            mouseover = false,
            target = false,
            selfCast = false,
        }
    elseif spellData.isItem then
        -- Item binding (equipment slot or consumable)
        newBinding.actionType = self.ACTION_TYPES.ITEM
        newBinding.itemType = spellData.itemType
        if spellData.itemType == "slot" then
            newBinding.itemSlot = spellData.itemSlot
            newBinding.itemName = spellData.slotName or spellData.name
        else
            newBinding.itemId = spellData.itemId
            newBinding.itemName = spellData.name
        end
    elseif spellData.actionType and not spellData.spellName then
        newBinding.actionType = spellData.actionType
    else
        newBinding.actionType = self.ACTION_TYPES.SPELL
        newBinding.spellId = spellData.spellId
        newBinding.spellName = spellData.spellName or spellData.name
    end
    
    -- Hide popup and capture frame
    self:HideKeybindPopup()
    
    -- Check for duplicate binding
    local duplicateIndex = self:FindDuplicateBinding(newBinding)
    if duplicateIndex then
        print("|cffff9900DandersFrames:|r " .. L["That binding already exists."])
        return
    end

    -- Check for key conflicts (same key combo, different action)
    local conflicts = self:FindKeyConflicts(newBinding, nil)
    if #conflicts > 0 then
        -- Store the pending binding for later
        self.pendingQuickBinding = newBinding
        
        -- Build conflict description
        local conflictDesc = ""
        for i, conflict in ipairs(conflicts) do
            local existingBinding = conflict.binding
            local actionName = self:GetBindingActionText(existingBinding) or "Unknown"
            if i > 1 then conflictDesc = conflictDesc .. "\n" end
            conflictDesc = conflictDesc .. "• " .. actionName
            if i >= 3 and #conflicts > 3 then
                conflictDesc = conflictDesc .. "\n• ... and " .. (#conflicts - 3) .. " more"
                break
            end
        end
        
        local keyText = self:GetBindingKeyText(newBinding)
        
        -- Show warning popup
        StaticPopupDialogs["DF_QUICKBIND_CONFLICT_WARNING"] = {
            text = "|c" .. DF.GUI:ToneHex("danger") .. L["Warning:"] .. "|r " .. keyText .. " " .. L["is already bound to:"] .. "\n\n" .. conflictDesc .. "\n\n" .. L["Multiple bindings on the same key may not work as expected. Save anyway?"],
            button1 = L["Save Anyway"],
            button2 = L["Cancel"],
            OnAccept = function()
                CC:CommitQuickBinding()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        ShowPopupOnTop("DF_QUICKBIND_CONFLICT_WARNING")
        return
    end
    
    -- No conflicts, add directly
    self:CommitQuickBindingDirect(newBinding)
end

-- Commit the quick binding (called after conflict warning is accepted)
function CC:CommitQuickBinding()
    if not self.pendingQuickBinding then return end
    self:CommitQuickBindingDirect(self.pendingQuickBinding)
    self.pendingQuickBinding = nil
end

-- Actually add the quick binding
function CC:CommitQuickBindingDirect(newBinding)
    -- Add new binding (multiple bindings on same key allowed for fallback functionality)
    table.insert(self.db.bindings, newBinding)
    
    -- Debug for item bindings
    if newBinding.actionType == self.ACTION_TYPES.ITEM then
        print("|cff00ff00DF:|r Item binding added - " .. (newBinding.itemName or "?") .. " (" .. (newBinding.itemType or "?") .. ") total=" .. #self.db.bindings)
    end
    
    self:UpdateBlizzardFrameRegistration()
    self:ApplyBindings()
    self:RefreshSpellGrid(true)  -- Skip scroll reset to maintain position
end

function CC:GetBindingsForSpell(spellName, displaySpellId)
    local bindings = {}
    
    -- If we have a displaySpellId, we can match bindings that resolve to the same display
    -- This handles transformation chains like Divine Toll/Holy Bulwark -> Sacred Weapon
    -- and Living Flame -> Chrono Flames
    for i, binding in ipairs(self.db.bindings) do
        if binding.spellName then
            -- Direct name match
            if binding.spellName == spellName then
                table.insert(bindings, binding)
            -- Check if this binding resolves to the same display spell
            elseif displaySpellId and binding.spellId then
                local _, _, bindingDisplayId = GetSpellDisplayInfo(binding.spellId, binding.spellName)
                if bindingDisplayId and bindingDisplayId == displaySpellId then
                    table.insert(bindings, binding)
                else
                    -- Also check if the binding's spell has the same root as our target
                    -- e.g., if binding is for "Living Flame" (361469) and we're showing Chrono Flames
                    local bindingRootId = binding.spellId
                    if C_Spell.GetBaseSpell then
                        local baseId = C_Spell.GetBaseSpell(binding.spellId)
                        if baseId then
                            bindingRootId = baseId
                        end
                    end
                    
                    -- Get our target spell's root
                    local targetRootId = displaySpellId
                    if C_Spell.GetBaseSpell then
                        local baseId = C_Spell.GetBaseSpell(displaySpellId)
                        if baseId then
                            targetRootId = baseId
                        end
                    end
                    
                    -- Match if roots are the same
                    if bindingRootId == targetRootId then
                        table.insert(bindings, binding)
                    end
                end
            end
        end
    end
    return bindings
end

function CC:GetBindingsForAction(actionType)
    local bindings = {}
    for i, binding in ipairs(self.db.bindings) do
        if binding.actionType == actionType and not binding.spellName then
            table.insert(bindings, binding)
        end
    end
    return bindings
end

function CC:CreateSpellCell(parent, spellData, index)
    local themeColor = CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    local cellWidth = 85
    local cellHeight = 75
    
    local cell = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetSize(cellWidth, cellHeight)
    cell:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    cell:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.8)
    cell:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    cell:RegisterForClicks("AnyDown")
    
    -- Get display info (shows current override name/icon for talent-modified spells)
    local displayName, displayIcon, displaySpellId
    if spellData.spellId then
        displayName, displayIcon, displaySpellId = GetSpellDisplayInfo(spellData.spellId, spellData.name)
    else
        displayName = spellData.name
        displayIcon = spellData.icon
        displaySpellId = spellData.spellId
    end
    
    -- Icon (larger now that we don't have binding text)
    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOP", 0, -5)
    icon:SetSize(40, 40)
    icon:SetTexture(displayIcon or spellData.icon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    
    -- Name (use current display name, can wrap to 2 lines)
    local name = cell:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    name:SetPoint("TOP", icon, "BOTTOM", 0, -2)
    name:SetPoint("BOTTOM", 0, 3)
    name:SetWidth(cellWidth - 4)
    name:SetText(displayName or spellData.name)
    name:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    name:SetWordWrap(true)
    name:SetMaxLines(2)
    
    -- Check for existing binding - just set border color, no text
    -- Pass displaySpellId to match bindings that resolve to the same displayed spell
    local existingBindings = CC:GetBindingsForSpell(spellData.name, displaySpellId)
    if #existingBindings > 0 then
        cell:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
    end
    
    cell.spellData = spellData
    cell.existingBindings = existingBindings
    cell.displaySpellId = displaySpellId  -- Store for tooltip
    
    -- Hover effects
    cell:SetScript("OnEnter", function(self)
        self:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
        
        -- Show tooltip (use current override spell ID for accurate tooltip)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.displaySpellId or spellData.spellId then
            GameTooltip:SetSpellByID(self.displaySpellId or spellData.spellId)
        else
            GameTooltip:SetText(spellData.name)
        end
        
        -- Show existing bindings in tooltip if any
        local bindings = self.existingBindings or CC:GetBindingsForSpell(spellData.name, self.displaySpellId)
        if #bindings > 0 then
            GameTooltip:AddLine(" ")
            local bindStrs = {}
            for _, b in ipairs(bindings) do
                table.insert(bindStrs, CC:GetBindingKeyText(b, true))
            end
            GameTooltip:AddLine(format(L["Bound: %s"], table.concat(bindStrs, ", ")), themeColor.r, themeColor.g, themeColor.b)
        end
        
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Left-click to add/edit binding"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    
    cell:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.8)
        GameTooltip:Hide()
    end)
    
    -- Click handlers
    cell:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            -- Pass BASE spell info for binding (spellData.name), but display will show override
            local spellInfo = {
                spellName = spellData.name,  -- Base name for binding
                spellId = spellData.spellId,  -- Base ID for binding
                name = spellData.name,
                icon = spellData.icon,
            }
            
            if CC.db.options.quickBindEnabled then
                -- Quick bind mode - show simple keybind popup
                CC:ShowKeybindPopup(spellInfo)
            else
                -- Full edit mode - show edit binding panel
                CC:ShowEditBindingPanel(spellInfo, nil, nil)
            end
        end
    end)
    
    return cell
end

function CC:RefreshSpellGrid(skipScrollReset)
    if not self.scrollContent then return end
    
    -- Save current scroll position before refresh (for access by sub-functions)
    self._savedScrollPos = nil
    if skipScrollReset and self.scrollFrame then
        self._savedScrollPos = self.scrollFrame:GetVerticalScroll()
    end
    
    -- Refresh the active bindings section
    self:RefreshActiveBindings()
    
    -- Update checkboxes
    if self.enableCb then
        self.enableCb:SetChecked(self.db.enabled)
    end
    if self.downCb then
        self.downCb:SetChecked(self.db.options.castOnDown)
    end
    if self.quickBindCb then
        self.quickBindCb:SetChecked(self.db.options.quickBindEnabled)
    end
    if self.UpdateSmartResText then
        self.UpdateSmartResText()
    end
    if self.UpdateProfileDropdown then
        self.UpdateProfileDropdown()
    end
    
    -- If profiles tab is active, show profiles panel and hide spell grid
    if self.activeTab == "profiles" then
        if self.spellGrid then self.spellGrid:Hide() end
        if self.profilesPanel then 
            self.profilesPanel:Show() 
            self:RefreshProfilesPanel()
        end
        return
    else
        if self.spellGrid then self.spellGrid:Show() end
        if self.profilesPanel then self.profilesPanel:Hide() end
    end
    
    -- Update dropdown values (if they exist)
    if self.showDropdown and self.showDropdown.SetValue then
        self.showDropdown:SetValue(self.selectedSpellType or "all")
    end
    
    -- Clear existing cells
    for _, cell in ipairs(CC.spellCells) do
        cell:Hide()
        cell:SetParent(nil)
    end
    wipe(CC.spellCells)
    
    -- Branch based on active tab
    if self.activeTab == "macros" then
        self:RefreshMacroGrid(skipScrollReset)
        return
    end
    
    if self.activeTab == "items" then
        self:RefreshItemsGrid(skipScrollReset)
        return
    end
    
    -- Get search filter from search box
    local searchFilter = self.searchBox and self.searchBox:GetText() or ""
    
    -- Initialize view mode button states
    if self.SetActiveLayout then
        self.SetActiveLayout(self.viewLayout or "grid")
    end
    if self.SetActiveSort then
        self.SetActiveSort(self.viewSort or "sectioned")
    end
    
    -- Determine layout and sort mode
    local viewLayout = self.viewLayout or "grid"
    local viewSort = self.viewSort or "sectioned"
    
    -- Calculate layout based on view layout
    local containerWidth = self.gridContainer:GetWidth() - 35
    local cellWidth, cellHeight, padding, cols
    
    if viewLayout == "list" then
        cellWidth = containerWidth
        cellHeight = 28  -- Smaller rows without binding text
        padding = 2
        cols = 1
    else
        cellWidth = 85   -- Smaller cells
        cellHeight = 75  -- Smaller height without binding text
        padding = 5
        cols = math.floor(containerWidth / (cellWidth + padding))
        if cols < 1 then cols = 1 end
    end
    
    local row, col = 0, 0
    local totalCells = 0
    local yOffset = 0  -- Track Y offset for list views
    
    -- Add special actions first (Target and Menu) - only if not text filtering and showing all spell types
    local spellTypeFilter = self.selectedSpellType or "all"
    if (not searchFilter or searchFilter == "") and spellTypeFilter == "all" then
        if viewLayout == "list" then
            -- List-style view special actions
            local targetRow = self:CreateSpellListRow(self.scrollContent, {name = L["Target Unit"], icon = "Interface\\CURSOR\\Crosshairs", spellId = nil}, 1, true, "target")
            targetRow:SetPoint("TOPLEFT", 0, -yOffset)
            table.insert(CC.spellCells, targetRow)
            totalCells = totalCells + 1
            yOffset = yOffset + cellHeight + padding
            row = row + 1
            
            local menuRow = self:CreateSpellListRow(self.scrollContent, {name = L["Open Menu"], icon = "Interface\\Buttons\\UI-GuildButton-OfficerNote-Up", spellId = nil}, 2, true, "menu")
            menuRow:SetPoint("TOPLEFT", 0, -yOffset)
            table.insert(CC.spellCells, menuRow)
            totalCells = totalCells + 1
            yOffset = yOffset + cellHeight + padding
            row = row + 1
            
            local focusRow = self:CreateSpellListRow(self.scrollContent, {name = L["Set Focus"], icon = "Interface\\Icons\\Ability_Hunter_MasterMarksman", spellId = nil}, 3, true, "focus")
            focusRow:SetPoint("TOPLEFT", 0, -yOffset)
            table.insert(CC.spellCells, focusRow)
            totalCells = totalCells + 1
            yOffset = yOffset + cellHeight + padding
            row = row + 1
            
            local assistRow = self:CreateSpellListRow(self.scrollContent, {name = L["Assist"], icon = "Interface\\Icons\\Ability_Hunter_SniperShot", spellId = nil}, 4, true, "assist")
            assistRow:SetPoint("TOPLEFT", 0, -yOffset)
            table.insert(CC.spellCells, assistRow)
            totalCells = totalCells + 1
            yOffset = yOffset + cellHeight + padding
            row = row + 1
        else
            -- Grid view special actions
            local targetCell = self:CreateSpecialActionCell(self.scrollContent, "target", L["Target Unit"], "Interface\\CURSOR\\Crosshairs")
            targetCell:SetPoint("TOPLEFT", col * (cellWidth + padding), -row * (cellHeight + padding))
            table.insert(CC.spellCells, targetCell)
            totalCells = totalCells + 1
            col = col + 1
            if col >= cols then col = 0; row = row + 1 end
            
            local menuCell = self:CreateSpecialActionCell(self.scrollContent, "menu", L["Open Menu"], "Interface\\Buttons\\UI-GuildButton-OfficerNote-Up")
            menuCell:SetPoint("TOPLEFT", col * (cellWidth + padding), -row * (cellHeight + padding))
            table.insert(CC.spellCells, menuCell)
            totalCells = totalCells + 1
            col = col + 1
            if col >= cols then col = 0; row = row + 1 end
        end
    end
    
    -- Get all spells
    local spells = self:GetAllPlayerSpells()
    
    -- Apply search filter and spell type filter
    local filteredSpells = {}
    local lowerSearchFilter = searchFilter:lower()
    
    for _, spell in ipairs(spells) do
        -- Search against both base name and display name (for overrides like Chrono Flames)
        local baseName = spell.name or ""
        local displayName = spell.displayName or baseName
        local passesSearch = (searchFilter == "") or 
            baseName:lower():find(lowerSearchFilter, 1, true) or
            displayName:lower():find(lowerSearchFilter, 1, true)
        
        -- Check spell type filter
        local passesTypeFilter = true
        if spellTypeFilter ~= "all" and spell.spellId then
            local isHelpful = C_Spell.IsSpellHelpful(spell.spellId)
            local isHarmful = C_Spell.IsSpellHarmful(spell.spellId)
            
            if spellTypeFilter == "helpful" then
                passesTypeFilter = isHelpful
            elseif spellTypeFilter == "harmful" then
                passesTypeFilter = isHarmful
            end
        end
        
        if passesSearch and passesTypeFilter then
            table.insert(filteredSpells, spell)
        end
    end
    
    -- Sort spells based on viewSort mode
    table.sort(filteredSpells, function(a, b)
        if viewSort == "sectioned" then
            -- Sectioned mode: sort by category priority, then alphabetically
            -- Bound and unbound spells are mixed together within categories
            local aPriority = a.categoryPriority or 99
            local bPriority = b.categoryPriority or 99
            
            if aPriority ~= bPriority then
                return aPriority < bPriority
            end
            
            -- Within same category, sort alphabetically
            return a.name < b.name
        elseif viewSort == "alphabetical" then
            -- Pure alphabetical
            return a.name < b.name
        else
            -- Priority mode: bound spells first, then by category
            -- Get displaySpellId for proper override matching
            local _, _, aDisplayId = GetSpellDisplayInfo(a.spellId, a.name)
            local _, _, bDisplayId = GetSpellDisplayInfo(b.spellId, b.name)
            local aBindings = CC:GetBindingsForSpell(a.name, aDisplayId)
            local bBindings = CC:GetBindingsForSpell(b.name, bDisplayId)
            local aHasBinding = #aBindings > 0
            local bHasBinding = #bBindings > 0
            
            -- Bound spells come first
            if aHasBinding and not bHasBinding then
                return true
            elseif not aHasBinding and bHasBinding then
                return false
            end
            
            -- Within same binding status, sort by category then alphabetically
            local aPriority = a.categoryPriority or 99
            local bPriority = b.categoryPriority or 99
            
            if aPriority ~= bPriority then
                return aPriority < bPriority
            end
            
            return a.name < b.name
        end
    end)
    
    -- Helper function to create section header (for sectioned sort mode)
    local function CreateSectionHeader(parent, text, yPos)
        local header = CreateFrame("Frame", nil, parent)
        header:SetSize(containerWidth, 24)
        header:SetPoint("TOPLEFT", 0, -yPos)
        
        local label = header:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        label:SetPoint("LEFT", 5, 0)
        label:SetText(text)
        label:SetTextColor(0.2, 0.8, 0.4, 1)  -- Theme color
        
        local line = header:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("LEFT", label, "RIGHT", 8, 0)
        line:SetPoint("RIGHT", header, "RIGHT", -5, 0)
        line:SetColorTexture(0.3, 0.3, 0.3, 0.8)
        
        return header
    end
    
    -- Category names for section headers (no Bound category - use Active Bindings for that)
    local categoryNames = {
        [1] = L["Specialization"],
        [2] = L["Class"],
        [3] = L["Racial"],
        [4] = L["Other"],
        [5] = L["Guild"],
    }
    
    -- Create spell cells based on layout and sort mode
    if viewSort == "sectioned" then
        -- Sectioned mode: show category headers
        local currentSection = nil
        local headerHeight = 24
        
        if viewLayout == "list" then
            -- List layout with sections
            for i, spell in ipairs(filteredSpells) do
                local spellCategory = spell.categoryPriority or 99
                
                -- Use the spell's natural category
                local sectionKey = spellCategory
                
                -- Create section header if section changed
                if sectionKey ~= currentSection then
                    currentSection = sectionKey
                    local headerText = categoryNames[sectionKey] or L["Other"]
                    local header = CreateSectionHeader(self.scrollContent, headerText, yOffset)
                    table.insert(CC.spellCells, header)
                    yOffset = yOffset + headerHeight + padding
                end
                
                local cell = self:CreateSpellListRow(self.scrollContent, spell, i, false, nil)
                cell:SetPoint("TOPLEFT", 0, -yOffset)
                table.insert(CC.spellCells, cell)
                totalCells = totalCells + 1
                yOffset = yOffset + cellHeight + padding
            end
            
            self.scrollContent:SetHeight(math.max(200, yOffset + padding))
            self.scrollContent:SetWidth(containerWidth)
        else
            -- Grid layout with sections
            local gridYOffset = 0  -- Track vertical position with smaller header heights
            local gridHeaderHeight = 28  -- Smaller header for grid
            
            for i, spell in ipairs(filteredSpells) do
                local spellCategory = spell.categoryPriority or 99
                
                -- Use the spell's natural category
                local sectionKey = spellCategory
                
                -- Create section header if section changed
                if sectionKey ~= currentSection then
                    -- Finish current row if we were mid-row
                    if col > 0 then
                        gridYOffset = gridYOffset + cellHeight + padding
                        col = 0
                    end
                    
                    currentSection = sectionKey
                    local headerText = categoryNames[sectionKey] or L["Other"]
                    local header = CreateSectionHeader(self.scrollContent, headerText, gridYOffset)
                    table.insert(CC.spellCells, header)
                    gridYOffset = gridYOffset + gridHeaderHeight  -- Smaller spacing after header
                end
                
                local cell = self:CreateSpellCell(self.scrollContent, spell, i)
                cell:SetPoint("TOPLEFT", col * (cellWidth + padding), -gridYOffset)
                table.insert(CC.spellCells, cell)
                totalCells = totalCells + 1
                col = col + 1
                if col >= cols then
                    col = 0
                    gridYOffset = gridYOffset + cellHeight + padding
                end
            end
            
            -- Account for partial last row
            if col > 0 then 
                gridYOffset = gridYOffset + cellHeight + padding
            end
            self.scrollContent:SetHeight(math.max(200, gridYOffset + padding))
            self.scrollContent:SetWidth(containerWidth)
        end
    else
        -- Priority or Alphabetical mode: no section headers
        if viewLayout == "list" then
            for i, spell in ipairs(filteredSpells) do
                local cell = self:CreateSpellListRow(self.scrollContent, spell, i, false, nil)
                cell:SetPoint("TOPLEFT", 0, -yOffset)
                table.insert(CC.spellCells, cell)
                totalCells = totalCells + 1
                yOffset = yOffset + cellHeight + padding
            end
            
            self.scrollContent:SetHeight(math.max(200, yOffset + padding))
            self.scrollContent:SetWidth(containerWidth)
        else
            -- Grid layout
            for i, spell in ipairs(filteredSpells) do
                local cell = self:CreateSpellCell(self.scrollContent, spell, i)
                cell:SetPoint("TOPLEFT", col * (cellWidth + padding), -row * (cellHeight + padding))
                table.insert(CC.spellCells, cell)
                totalCells = totalCells + 1
                col = col + 1
                if col >= cols then
                    col = 0
                    row = row + 1
                end
            end
            
            -- Account for partial last row
            if col > 0 then row = row + 1 end
            self.scrollContent:SetHeight(math.max(200, row * (cellHeight + padding) + padding))
            self.scrollContent:SetWidth(containerWidth)
        end
    end
    
    -- Restore scroll position after refresh (use timer to ensure content is fully laid out)
    if self._savedScrollPos and self.scrollFrame then
        C_Timer.After(0, function()
            if CC.scrollFrame then
                CC.scrollFrame:SetVerticalScroll(CC._savedScrollPos or 0)
            end
        end)
    elseif not self._savedScrollPos and self.scrollFrame then
        -- Reset to top when not preserving position
        self.scrollFrame:SetVerticalScroll(0)
    end
end

-- Refresh the macro grid (when Macros tab is active)
function CC:RefreshMacroGrid(skipScrollReset)
    local themeColor = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor() or CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    -- Get search filter
    local searchFilter = self.searchBox and self.searchBox:GetText() or ""
    local lowerSearchFilter = searchFilter:lower()
    
    -- Initialize view mode button states
    if self.SetActiveLayout then
        self.SetActiveLayout(self.viewLayout or "grid")
    end
    if self.SetActiveSort then
        self.SetActiveSort(self.viewSort or "sectioned")
    end
    
    -- Determine layout
    local viewLayout = self.viewLayout or "grid"
    local containerWidth = self.gridContainer:GetWidth() - 35
    local cellWidth, cellHeight, padding, cols
    
    if viewLayout == "list" then
        cellWidth = containerWidth
        cellHeight = 32
        padding = 2
        cols = 1
    else
        cellWidth = 100
        cellHeight = 95
        padding = 5
        cols = math.floor(containerWidth / (cellWidth + padding))
        if cols < 1 then cols = 1 end
    end
    
    -- Get macros filtered by source
    local sourceFilter = self.selectedMacroSource or "all"
    local allMacros = self:GetMacrosBySource(sourceFilter)
    
    -- Apply search filter
    local filteredMacros = {}
    for _, macro in ipairs(allMacros) do
        local passesSearch = (searchFilter == "") or macro.name:lower():find(lowerSearchFilter, 1, true)
        if passesSearch then
            table.insert(filteredMacros, macro)
        end
    end
    
    -- Sort macros based on viewSort mode
    local viewSort = self.viewSort or "sectioned"
    
    -- For "sectioned" mode with macros, group by category (source)
    if viewSort == "sectioned" or viewSort == "categories" then
        -- Sort by source first, then by binding status, then alphabetically
        table.sort(filteredMacros, function(a, b)
            -- Source order: custom first, then global_import, then char_import
            local sourceOrder = { custom = 1, global_import = 2, char_import = 3 }
            local aOrder = sourceOrder[a.source] or 4
            local bOrder = sourceOrder[b.source] or 4
            
            if aOrder ~= bOrder then
                return aOrder < bOrder
            end
            
            -- Within same source, bound macros first
            local aBindings = self:GetBindingsForMacro(a.id)
            local bBindings = self:GetBindingsForMacro(b.id)
            local aHasBinding = #aBindings > 0
            local bHasBinding = #bBindings > 0
            
            if aHasBinding and not bHasBinding then return true end
            if not aHasBinding and bHasBinding then return false end
            
            return a.name < b.name
        end)
    else
        -- Alphabetical mode
        table.sort(filteredMacros, function(a, b)
            return a.name < b.name
        end)
    end
    
    local row, col = 0, 0
    local yOffset = 0
    
    -- Track current category for headers
    local currentSource = nil
    local sourceNames = {
        custom = L["Custom Macros"],
        global_import = L["General Imports"],
        char_import = L["Character Imports"],
    }
    
    -- Helper to create category header
    local function CreateCategoryHeader(parent, text, y)
        local headerFrame = CreateFrame("Frame", nil, parent)
        headerFrame:SetSize(containerWidth, 20)
        headerFrame:SetPoint("TOPLEFT", 0, -y)
        
        local header = headerFrame:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        header:SetPoint("LEFT", 4, 0)
        header:SetText(text)
        header:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
        
        -- Underline
        local line = headerFrame:CreateTexture(nil, "ARTWORK")
        line:SetPoint("BOTTOMLEFT", 0, 0)
        line:SetPoint("BOTTOMRIGHT", 0, 0)
        line:SetHeight(1)
        line:SetColorTexture(themeColor.r * 0.5, themeColor.g * 0.5, themeColor.b * 0.5, 0.5)
        
        return headerFrame
    end
    
    -- Show empty state if no macros
    if #filteredMacros == 0 then
        local emptyMsg = self.scrollContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        emptyMsg:SetPoint("CENTER", 0, 0)
        if #self:GetAllMacros() == 0 then
            emptyMsg:SetText(L["No macros yet.\nClick '+ New' to create one or 'Import' to import from WoW."])
        else
            emptyMsg:SetText(L["No macros match the current filter."])
        end
        emptyMsg:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        table.insert(CC.spellCells, emptyMsg)
        self.scrollContent:SetHeight(200)
        return
    end
    
    -- Create cells/rows for macros
    local showCategoryHeaders = (viewSort == "sectioned" or viewSort == "categories")
    local headerHeight = 22
    
    if viewLayout == "list" then
        for i, macro in ipairs(filteredMacros) do
            -- Add category header if source changed
            if showCategoryHeaders and macro.source ~= currentSource then
                currentSource = macro.source
                local headerText = sourceNames[macro.source] or L["Other"]
                local header = CreateCategoryHeader(self.scrollContent, headerText, yOffset)
                table.insert(CC.spellCells, header)
                yOffset = yOffset + headerHeight
            end
            
            local listRow = self:CreateMacroListRow(self.scrollContent, macro, i)
            listRow:SetPoint("TOPLEFT", 0, -yOffset)
            table.insert(CC.spellCells, listRow)
            yOffset = yOffset + cellHeight + padding
        end
        self.scrollContent:SetHeight(math.max(200, yOffset + padding))
    else
        local gridYOffset = 0
        for i, macro in ipairs(filteredMacros) do
            -- Add category header if source changed
            if showCategoryHeaders and macro.source ~= currentSource then
                -- If we're mid-row, move to next row first
                if col > 0 then
                    col = 0
                    gridYOffset = gridYOffset + cellHeight + padding
                end
                
                currentSource = macro.source
                local headerText = sourceNames[macro.source] or L["Other"]
                local header = CreateCategoryHeader(self.scrollContent, headerText, gridYOffset)
                table.insert(CC.spellCells, header)
                gridYOffset = gridYOffset + headerHeight
            end
            
            local cell = self:CreateMacroCell(self.scrollContent, macro, i)
            cell:SetPoint("TOPLEFT", col * (cellWidth + padding), -gridYOffset)
            table.insert(CC.spellCells, cell)
            col = col + 1
            if col >= cols then
                col = 0
                gridYOffset = gridYOffset + cellHeight + padding
            end
        end
        if col > 0 then gridYOffset = gridYOffset + cellHeight + padding end
        self.scrollContent:SetHeight(math.max(200, gridYOffset + padding))
    end
    
    self.scrollContent:SetWidth(containerWidth)
    
    -- Restore scroll position after refresh
    if self._savedScrollPos and self.scrollFrame then
        C_Timer.After(0, function()
            if CC.scrollFrame then
                CC.scrollFrame:SetVerticalScroll(CC._savedScrollPos or 0)
            end
        end)
    end
end

-- Refresh items grid
function CC:RefreshItemsGrid(skipScrollReset)
    local themeColor = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor() or CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    local C_BACKGROUND = {r = 0.12, g = 0.12, b = 0.12}
    
    -- Initialize view mode button states
    if self.SetActiveLayout then
        self.SetActiveLayout(self.viewLayout or "grid")
    end
    
    -- Determine layout
    local viewLayout = self.viewLayout or "grid"
    local containerWidth = self.gridContainer:GetWidth() - 35
    local cellWidth, cellHeight, padding, cols
    
    if viewLayout == "list" then
        cellWidth = containerWidth
        cellHeight = 36
        padding = 2
        cols = 1
    else
        cellWidth = 100
        cellHeight = 95
        padding = 5
        cols = math.floor(containerWidth / (cellWidth + padding))
        if cols < 1 then cols = 1 end
    end
    
    local yOffset = 0
    local col = 0
    
    -- Helper to create section header
    local function CreateSectionHeader(parent, text, y)
        local headerFrame = CreateFrame("Frame", nil, parent)
        headerFrame:SetSize(containerWidth, 22)
        headerFrame:SetPoint("TOPLEFT", 0, -y)
        
        local headerText = headerFrame:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        headerText:SetPoint("LEFT", 4, 0)
        headerText:SetText(text)
        headerText:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
        
        local line = headerFrame:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("LEFT", headerText, "RIGHT", 8, 0)
        line:SetPoint("RIGHT", -4, 0)
        line:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        
        return headerFrame
    end
    
    -- Equipment Slots Section
    local equipHeader = CreateSectionHeader(self.scrollContent, L["Equipment Slots"], yOffset)
    table.insert(CC.spellCells, equipHeader)
    yOffset = yOffset + 26
    col = 0
    
    for i, slotData in ipairs(self.EQUIPMENT_SLOTS) do
        local slotInfo = self:GetSlotItemInfo(slotData.slot)
        local itemData = {
            slot = slotData.slot,
            slotName = slotData.name,
            defaultIcon = slotData.icon,
            itemInfo = slotInfo,
        }
        
        local cell
        if viewLayout == "list" then
            cell = self:CreateItemListRow(self.scrollContent, itemData, i)
            cell:SetPoint("TOPLEFT", 0, -yOffset)
            yOffset = yOffset + cellHeight + padding
        else
            cell = self:CreateItemCell(self.scrollContent, itemData, i)
            cell:SetPoint("TOPLEFT", col * (cellWidth + padding), -yOffset)
            col = col + 1
            if col >= cols then
                col = 0
                yOffset = yOffset + cellHeight + padding
            end
        end
        table.insert(CC.spellCells, cell)
    end
    
    -- Finish current row if grid layout
    if viewLayout ~= "list" and col > 0 then
        yOffset = yOffset + cellHeight + padding
    end
    
    -- Add some spacing before consumables
    yOffset = yOffset + 10
    
    -- Consumables Section
    local consumHeader = CreateSectionHeader(self.scrollContent, L["Consumables (Drag items here)"], yOffset)
    table.insert(CC.spellCells, consumHeader)
    yOffset = yOffset + 26
    col = 0
    
    -- Get saved consumables from db
    local consumables = self.db.savedConsumables or {}
    
    -- Add common consumables that aren't already saved
    local seenItems = {}
    for _, cons in ipairs(consumables) do
        seenItems[cons.itemId] = true
    end
    
    -- Display saved consumables
    for i, cons in ipairs(consumables) do
        local itemInfo = self:GetItemInfoById(cons.itemId)
        local itemData = {
            itemType = "consumable",
            itemId = cons.itemId,
            itemInfo = itemInfo,
            savedIndex = i,
        }
        
        local cell
        if viewLayout == "list" then
            cell = self:CreateConsumableListRow(self.scrollContent, itemData, i)
            cell:SetPoint("TOPLEFT", 0, -yOffset)
            yOffset = yOffset + cellHeight + padding
        else
            cell = self:CreateConsumableCell(self.scrollContent, itemData, i)
            cell:SetPoint("TOPLEFT", col * (cellWidth + padding), -yOffset)
            col = col + 1
            if col >= cols then
                col = 0
                yOffset = yOffset + cellHeight + padding
            end
        end
        table.insert(CC.spellCells, cell)
    end
    
    -- Finish current row
    if viewLayout ~= "list" and col > 0 then
        yOffset = yOffset + cellHeight + padding
        col = 0
    end
    
    -- Drop zone for adding new consumables
    local dropZone = CreateFrame("Button", nil, self.scrollContent, "BackdropTemplate")
    if viewLayout == "list" then
        dropZone:SetSize(containerWidth, 40)
    else
        dropZone:SetSize(cellWidth, cellHeight)
    end
    dropZone:SetPoint("TOPLEFT", col * (cellWidth + padding), -yOffset)
    dropZone:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    dropZone:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.5)
    dropZone:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.3)
    
    local dropText = dropZone:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    dropText:SetPoint("CENTER")
    dropText:SetText(L["+ Drop Item"])
    dropText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Handle item drops
    dropZone:SetScript("OnReceiveDrag", function()
        local infoType, itemId = GetCursorInfo()
        if infoType == "item" and itemId then
            ClearCursor()
            -- Add to saved consumables
            if not self.db.savedConsumables then
                self.db.savedConsumables = {}
            end
            -- Check if already saved
            for _, cons in ipairs(self.db.savedConsumables) do
                if cons.itemId == itemId then
                    print("|cff00ff00DandersFrames:|r " .. L["Item already in list"])
                    return
                end
            end
            local itemName = C_Item.GetItemInfo(itemId)
            table.insert(self.db.savedConsumables, {
                itemId = itemId,
                name = itemName or L["Unknown Item"],
            })
            self:RefreshSpellGrid(true)  -- Skip scroll reset to maintain position
        end
    end)
    
    dropZone:SetScript("OnClick", function()
        -- Same as receive drag
        local infoType, itemId = GetCursorInfo()
        if infoType == "item" and itemId then
            ClearCursor()
            if not self.db.savedConsumables then
                self.db.savedConsumables = {}
            end
            for _, cons in ipairs(self.db.savedConsumables) do
                if cons.itemId == itemId then
                    print("|cff00ff00DandersFrames:|r " .. L["Item already in list"])
                    return
                end
            end
            local itemName = C_Item.GetItemInfo(itemId)
            table.insert(self.db.savedConsumables, {
                itemId = itemId,
                name = itemName or L["Unknown Item"],
            })
            self:RefreshSpellGrid(true)  -- Skip scroll reset to maintain position
        end
    end)
    
    dropZone:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.8)
        dropText:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    end)
    dropZone:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.3)
        dropText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end)
    
    table.insert(CC.spellCells, dropZone)
    
    if viewLayout == "list" then
        yOffset = yOffset + 44
    else
        yOffset = yOffset + cellHeight + padding
    end
    
    self.scrollContent:SetHeight(math.max(200, yOffset + padding))
    self.scrollContent:SetWidth(containerWidth)
    
    -- Restore scroll position after refresh
    if self._savedScrollPos and self.scrollFrame then
        C_Timer.After(0, function()
            if CC.scrollFrame then
                CC.scrollFrame:SetVerticalScroll(CC._savedScrollPos or 0)
            end
        end)
    end
end

-- Create a grid cell for an equipment slot item
function CC:CreateItemCell(parent, itemData, index)
    local themeColor = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor() or CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    local cellWidth = 85
    local cellHeight = 75
    
    local cell = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetSize(cellWidth, cellHeight)
    cell:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    cell:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    cell:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    -- Icon
    local iconSize = 40
    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("TOP", 0, -5)
    
    local itemInfo = itemData.itemInfo
    if itemInfo and itemInfo.icon then
        icon:SetTexture(itemInfo.icon)
    else
        icon:SetTexture(itemData.defaultIcon)
        icon:SetVertexColor(0.5, 0.5, 0.5, 0.8)
    end
    
    -- Item name
    local nameText = cell:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    nameText:SetPoint("TOP", icon, "BOTTOM", 0, -2)
    nameText:SetPoint("BOTTOM", 0, 3)
    nameText:SetWidth(cellWidth - 4)
    nameText:SetJustifyH("CENTER")
    nameText:SetWordWrap(true)
    nameText:SetMaxLines(2)
    
    if itemInfo and itemInfo.name then
        nameText:SetText(itemInfo.name)
        nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    else
        nameText:SetText(itemData.slotName)
        nameText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end
    
    -- On-Use indicator: a small corner badge. Give it a dark backing pill on a high
    -- OVERLAY sublevel so it reads clearly instead of blending into the icon art.
    if itemInfo and itemInfo.hasOnUse then
        local onUseBadge = cell:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        onUseBadge:SetDrawLayer("OVERLAY", 7)
        onUseBadge:SetPoint("TOPLEFT", 4, -4)
        onUseBadge:SetText(L["USE"])
        onUseBadge:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
        local onUseBg = cell:CreateTexture(nil, "OVERLAY")
        onUseBg:SetDrawLayer("OVERLAY", 6)
        onUseBg:SetColorTexture(0, 0, 0, 0.7)
        onUseBg:SetPoint("TOPLEFT", onUseBadge, "TOPLEFT", -3, 2)
        onUseBg:SetPoint("BOTTOMRIGHT", onUseBadge, "BOTTOMRIGHT", 3, -2)
    end
    
    -- Check for existing binding - just set border color (no text)
    local bindings = self:GetBindingsForItem(itemData.slot)
    if #bindings > 0 then
        cell:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
    end
    
    cell.itemData = itemData
    cell.existingBindings = bindings
    
    -- Hover effect
    cell:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_ELEMENT.r + 0.08, C_ELEMENT.g + 0.08, C_ELEMENT.b + 0.08, 1)
        
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if itemInfo then
            GameTooltip:SetInventoryItem("player", itemData.slot)
        else
            GameTooltip:AddLine(itemData.slotName, 1, 1, 1)
            GameTooltip:AddLine(L["No item equipped"], 0.5, 0.5, 0.5)
        end
        
        -- Show existing bindings in tooltip
        local myBindings = self.existingBindings
        if myBindings and #myBindings > 0 then
            GameTooltip:AddLine(" ")
            local bindStrs = {}
            for _, b in ipairs(myBindings) do
                table.insert(bindStrs, CC:GetBindingKeyText(b, true))
            end
            GameTooltip:AddLine(format(L["Bound: %s"], table.concat(bindStrs, ", ")), themeColor.r, themeColor.g, themeColor.b)
        end
        
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Left-click to add/edit binding"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        if #(self.existingBindings or {}) == 0 then
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        end
        GameTooltip:Hide()
    end)
    
    -- Click to bind
    cell:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            CC:ShowItemKeybindPopup(itemData)
        end
    end)
    
    return cell
end

-- Create a list row for an equipment slot item
function CC:CreateItemListRow(parent, itemData, index)
    local themeColor = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor() or CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    local containerWidth = self.gridContainer:GetWidth() - 35
    
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(containerWidth, 28)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    row:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    row:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", 4, 0)
    
    local itemInfo = itemData.itemInfo
    if itemInfo and itemInfo.icon then
        icon:SetTexture(itemInfo.icon)
    else
        icon:SetTexture(itemData.defaultIcon)
        icon:SetVertexColor(0.5, 0.5, 0.5, 0.8)
    end
    
    -- Slot name
    local slotText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    slotText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    slotText:SetText(itemData.slotName)
    slotText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Item name
    local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    nameText:SetPoint("LEFT", slotText, "RIGHT", 8, 0)
    if itemInfo and itemInfo.name then
        nameText:SetText(itemInfo.name)
        nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    else
        nameText:SetText(L["(Empty)"])
        nameText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end
    
    -- On-Use badge
    if itemInfo and itemInfo.hasOnUse then
        local onUseBadge = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        onUseBadge:SetPoint("LEFT", nameText, "RIGHT", 8, 0)
        onUseBadge:SetText("[" .. L["USE"] .. "]")
        onUseBadge:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    end
    
    -- Check for existing binding - just set border color (no text)
    local bindings = self:GetBindingsForItem(itemData.slot)
    if #bindings > 0 then
        row:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
    end
    
    row.itemData = itemData
    row.existingBindings = bindings
    
    -- Hover
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_ELEMENT.r + 0.08, C_ELEMENT.g + 0.08, C_ELEMENT.b + 0.08, 1)
        
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if itemInfo then
            GameTooltip:SetInventoryItem("player", itemData.slot)
        else
            GameTooltip:AddLine(itemData.slotName, 1, 1, 1)
            GameTooltip:AddLine(L["No item equipped"], 0.5, 0.5, 0.5)
        end
        
        -- Show existing bindings in tooltip
        local myBindings = self.existingBindings
        if myBindings and #myBindings > 0 then
            GameTooltip:AddLine(" ")
            local bindStrs = {}
            for _, b in ipairs(myBindings) do
                table.insert(bindStrs, CC:GetBindingKeyText(b, true))
            end
            GameTooltip:AddLine(format(L["Bound: %s"], table.concat(bindStrs, ", ")), themeColor.r, themeColor.g, themeColor.b)
        end
        
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Left-click to add/edit binding"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        if #(self.existingBindings or {}) == 0 then
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        end
        GameTooltip:Hide()
    end)
    
    -- Click to bind
    row:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            CC:ShowItemKeybindPopup(itemData)
        end
    end)
    
    return row
end

-- Create a grid cell for a consumable item
function CC:CreateConsumableCell(parent, itemData, index)
    local themeColor = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor() or CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    local cellWidth = 85
    local cellHeight = 75
    
    local cell = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetSize(cellWidth, cellHeight)
    cell:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    cell:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    cell:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    -- Icon
    local iconSize = 40
    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("TOP", 0, -5)
    
    local itemInfo = itemData.itemInfo
    if itemInfo and itemInfo.icon then
        icon:SetTexture(itemInfo.icon)
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end
    
    -- Item name
    local nameText = cell:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    nameText:SetPoint("TOP", icon, "BOTTOM", 0, -2)
    nameText:SetPoint("BOTTOM", 0, 3)
    nameText:SetWidth(cellWidth - 4)
    nameText:SetJustifyH("CENTER")
    nameText:SetWordWrap(true)
    nameText:SetMaxLines(2)
    
    if itemInfo and itemInfo.name then
        nameText:SetText(itemInfo.name)
    else
        nameText:SetText(L["Loading..."])
    end
    nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Item count
    local count = self:GetItemCount(itemData.itemId)
    if count > 0 then
        local countText = cell:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        countText:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -2, 2)
        countText:SetText(count)
        countText:SetTextColor(1, 1, 1)
    end
    
    -- Delete button (X)
    local deleteBtn = CreateFrame("Button", nil, cell)
    deleteBtn:SetSize(14, 14)
    deleteBtn:SetPoint("TOPRIGHT", -2, -2)
    local deleteIcon = deleteBtn:CreateTexture(nil, "OVERLAY")
    deleteIcon:SetPoint("CENTER")
    deleteIcon:SetSize(8, 8)
    deleteIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
    deleteIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    deleteBtn:SetScript("OnEnter", function() deleteIcon:SetVertexColor(1, 0.3, 0.3) end)
    deleteBtn:SetScript("OnLeave", function() deleteIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end)
    deleteBtn:SetScript("OnClick", function()
        if itemData.savedIndex and self.db.savedConsumables then
            table.remove(self.db.savedConsumables, itemData.savedIndex)
            self:RefreshSpellGrid(true)  -- Skip scroll reset to maintain position
        end
    end)
    
    -- Check for existing binding - just set border color (no text)
    local bindings = self:GetBindingsForConsumable(itemData.itemId)
    if #bindings > 0 then
        cell:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
    end
    
    cell.itemData = itemData
    cell.existingBindings = bindings
    
    -- Hover
    cell:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_ELEMENT.r + 0.08, C_ELEMENT.g + 0.08, C_ELEMENT.b + 0.08, 1)
        
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if itemData.itemId then
            GameTooltip:SetItemByID(itemData.itemId)
        end
        
        -- Show existing bindings in tooltip
        local myBindings = self.existingBindings
        if myBindings and #myBindings > 0 then
            GameTooltip:AddLine(" ")
            local bindStrs = {}
            for _, b in ipairs(myBindings) do
                table.insert(bindStrs, CC:GetBindingKeyText(b, true))
            end
            GameTooltip:AddLine(format(L["Bound: %s"], table.concat(bindStrs, ", ")), themeColor.r, themeColor.g, themeColor.b)
        end
        
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Left-click to add/edit binding"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        if #(self.existingBindings or {}) == 0 then
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        end
        GameTooltip:Hide()
    end)
    
    -- Click to bind
    cell:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            CC:ShowConsumableKeybindPopup(itemData)
        end
    end)
    
    return cell
end

-- Create a list row for a consumable item
function CC:CreateConsumableListRow(parent, itemData, index)
    local themeColor = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor() or CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    local containerWidth = self.gridContainer:GetWidth() - 35
    
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(containerWidth, 36)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    row:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    row:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("LEFT", 4, 0)
    
    local itemInfo = itemData.itemInfo
    if itemInfo and itemInfo.icon then
        icon:SetTexture(itemInfo.icon)
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end
    
    -- Item name
    local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    nameText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    if itemInfo and itemInfo.name then
        nameText:SetText(itemInfo.name)
    else
        nameText:SetText(L["Loading..."])
    end
    nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Item count
    local count = self:GetItemCount(itemData.itemId)
    if count > 0 then
        local countText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        countText:SetPoint("LEFT", nameText, "RIGHT", 8, 0)
        countText:SetText("(" .. count .. ")")
        countText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end
    
    -- Delete button
    local deleteBtn = CreateFrame("Button", nil, row)
    deleteBtn:SetSize(20, 20)
    deleteBtn:SetPoint("RIGHT", -4, 0)
    local deleteIcon = deleteBtn:CreateTexture(nil, "OVERLAY")
    deleteIcon:SetPoint("CENTER")
    deleteIcon:SetSize(10, 10)
    deleteIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
    deleteIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    deleteBtn:SetScript("OnEnter", function() deleteIcon:SetVertexColor(1, 0.3, 0.3) end)
    deleteBtn:SetScript("OnLeave", function() deleteIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end)
    deleteBtn:SetScript("OnClick", function()
        if itemData.savedIndex and self.db.savedConsumables then
            table.remove(self.db.savedConsumables, itemData.savedIndex)
            self:RefreshSpellGrid(true)  -- Skip scroll reset to maintain position
        end
    end)
    
    -- Binding display
    local bindings = self:GetBindingsForConsumable(itemData.itemId)
    if #bindings > 0 then
        local bindText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        bindText:SetPoint("RIGHT", deleteBtn, "LEFT", -8, 0)
        bindText:SetText(self:GetBindingDisplayText(bindings[1]))
        bindText:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    end
    
    -- Hover
    row:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
        if itemData.itemId then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(itemData.itemId)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        GameTooltip:Hide()
    end)
    
    -- Click to bind
    row:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            CC:ShowConsumableKeybindPopup(itemData)
        end
    end)
    
    return row
end

-- Get bindings for an equipment slot
function CC:GetBindingsForItem(slotId)
    local bindings = {}
    if not self.db or not self.db.bindings then return bindings end
    
    for _, binding in ipairs(self.db.bindings) do
        if binding.actionType == self.ACTION_TYPES.ITEM and 
           binding.itemType == "slot" and 
           binding.itemSlot == slotId then
            table.insert(bindings, binding)
        end
    end
    return bindings
end

-- Get bindings for a consumable
function CC:GetBindingsForConsumable(itemId)
    local bindings = {}
    if not self.db or not self.db.bindings then return bindings end
    
    for _, binding in ipairs(self.db.bindings) do
        if binding.actionType == self.ACTION_TYPES.ITEM and 
           binding.itemType == "consumable" and 
           binding.itemId == itemId then
            table.insert(bindings, binding)
        end
    end
    return bindings
end

-- Show keybind popup for equipment slot
function CC:ShowItemKeybindPopup(itemData)
    local itemInfo = itemData.itemInfo
    local displayName = (itemInfo and itemInfo.name) or itemData.slotName
    local displayIcon = (itemInfo and itemInfo.icon) or itemData.defaultIcon
    
    -- Create item data in spell format for the keybind popup
    local itemAsSpell = {
        name = displayName,
        icon = displayIcon,
        isItem = true,
        itemType = "slot",
        itemSlot = itemData.slot,
        slotName = itemData.slotName,
    }
    
    if self.db.options.quickBindEnabled then
        -- Quick bind mode - show simple keybind popup
        self:ShowKeybindPopup(itemAsSpell)
    else
        -- Full edit mode - show edit binding panel
        self:ShowEditBindingPanel(itemAsSpell, nil, nil)
    end
end

-- Show keybind popup for consumable
function CC:ShowConsumableKeybindPopup(itemData)
    local itemInfo = itemData.itemInfo
    local displayName = (itemInfo and itemInfo.name) or L["Unknown Item"]
    local displayIcon = (itemInfo and itemInfo.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
    
    local itemAsSpell = {
        name = displayName,
        icon = displayIcon,
        isItem = true,
        itemType = "consumable",
        itemId = itemData.itemId,
    }
    
    if self.db.options.quickBindEnabled then
        -- Quick bind mode - show simple keybind popup
        self:ShowKeybindPopup(itemAsSpell)
    else
        -- Full edit mode - show edit binding panel
        self:ShowEditBindingPanel(itemAsSpell, nil, nil)
    end
end

-- Create a grid cell for a macro
function CC:CreateMacroCell(parent, macroData, index)
    local themeColor = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor() or CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    local cellWidth = 85
    local cellHeight = 75
    
    local cell = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetSize(cellWidth, cellHeight)
    cell:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    cell:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    cell:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    cell:RegisterForClicks("AnyDown")
    
    -- Try to get icon: auto-detect from body first, then fall back to stored icon
    local iconToUse = nil
    if macroData.body then
        iconToUse = CC:GetIconFromMacroBody(macroData.body)
    end
    if not iconToUse and macroData.icon and type(macroData.icon) == "number" and macroData.icon > 0 then
        iconToUse = macroData.icon
    end
    
    -- Icon
    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(40, 40)
    icon:SetPoint("TOP", 0, -5)
    if iconToUse then
        icon:SetTexture(iconToUse)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    
    -- Source badge (Cus/Char/Gen)
    local sourceBadge = cell:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    sourceBadge:SetPoint("TOPRIGHT", -3, -3)
    if macroData.source == "global_import" then
        sourceBadge:SetText(L["[Gen]"])
        sourceBadge:SetTextColor(0.6, 0.8, 1)
    elseif macroData.source == "char_import" then
        sourceBadge:SetText(L["[Char]"])
        sourceBadge:SetTextColor(0.8, 0.6, 1)
    else
        sourceBadge:SetText(L["[Cus]"])
        sourceBadge:SetTextColor(1, 0.9, 0.4)
    end
    
    -- Out of sync indicator for imports
    if macroData.source == "global_import" or macroData.source == "char_import" then
        if CC:IsMacroOutOfSync(macroData.id) then
            local syncIcon = cell:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            syncIcon:SetPoint("TOPLEFT", 3, -3)
            syncIcon:SetText("!")
            syncIcon:SetTextColor(1, 0.8, 0)
        end
    end
    
    -- Name
    local name = cell:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    name:SetPoint("TOP", icon, "BOTTOM", 0, -2)
    name:SetPoint("BOTTOM", 0, 3)
    name:SetWidth(cellWidth - 4)
    name:SetText(macroData.name)
    name:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    name:SetWordWrap(true)
    name:SetMaxLines(2)
    
    -- Check for existing binding - just set border color (no text)
    local bindings = CC:GetBindingsForMacro(macroData.id)
    if #bindings > 0 then
        cell:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.8)
    end
    
    cell.macroData = macroData
    cell.existingBindings = bindings
    
    -- Hover effects
    cell:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_ELEMENT.r + 0.08, C_ELEMENT.g + 0.08, C_ELEMENT.b + 0.08, 1)
        
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(macroData.name, 1, 1, 1)
        if macroData.source == "global_import" then
            GameTooltip:AddLine(L["General Import"], 0.6, 0.8, 1)
        elseif macroData.source == "char_import" then
            GameTooltip:AddLine(L["Character Import"], 0.8, 0.6, 1)
        else
            GameTooltip:AddLine(L["Custom Macro"], 0.6, 1, 0.6)
        end
        
        -- Show existing bindings in tooltip
        local myBindings = self.existingBindings
        if myBindings and #myBindings > 0 then
            GameTooltip:AddLine(" ")
            local bindStrs = {}
            for _, b in ipairs(myBindings) do
                table.insert(bindStrs, CC:GetBindingKeyText(b, true))
            end
            GameTooltip:AddLine(format(L["Bound: %s"], table.concat(bindStrs, ", ")), themeColor.r, themeColor.g, themeColor.b)
        end
        
        GameTooltip:AddLine(" ")
        -- Show first 100 chars of body
        local bodyPreview = macroData.body or ""
        if #bodyPreview > 100 then
            bodyPreview = bodyPreview:sub(1, 100) .. "..."
        end
        GameTooltip:AddLine(bodyPreview, 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Left-click: Bind"], 0.5, 0.5, 0.5)
        GameTooltip:AddLine(L["Right-click: Edit/View"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    
    cell:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        GameTooltip:Hide()
    end)
    
    cell:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            -- Bind this macro
            CC:ShowKeybindPopupForMacro(macroData)
        elseif button == "RightButton" then
            -- Edit/view macro
            CC:ShowMacroEditorDialog(macroData)
        end
    end)
    
    return cell
end

-- Create a list row for a macro
function CC:CreateMacroListRow(parent, macroData, index)
    local themeColor = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor() or CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    local containerWidth = self.gridContainer:GetWidth() - 35
    local rowHeight = 28
    
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(containerWidth, rowHeight)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    row:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    row:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    row:RegisterForClicks("AnyDown")
    
    -- Try to get icon: auto-detect from body first, then fall back to stored icon
    local iconToUse = nil
    if macroData.body then
        iconToUse = CC:GetIconFromMacroBody(macroData.body)
    end
    if not iconToUse and macroData.icon and type(macroData.icon) == "number" and macroData.icon > 0 then
        iconToUse = macroData.icon
    end
    
    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", 4, 0)
    if iconToUse then
        icon:SetTexture(iconToUse)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    
    -- Source badge (Cus/Char/Gen)
    local sourceBadge = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    sourceBadge:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    if macroData.source == "global_import" then
        sourceBadge:SetText(L["[Gen]"])
        sourceBadge:SetTextColor(0.6, 0.8, 1)
    elseif macroData.source == "char_import" then
        sourceBadge:SetText(L["[Char]"])
        sourceBadge:SetTextColor(0.8, 0.6, 1)
    else
        sourceBadge:SetText(L["[Cus]"])
        sourceBadge:SetTextColor(1, 0.9, 0.4)
    end
    
    -- Name
    local name = row:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    name:SetPoint("LEFT", sourceBadge, "RIGHT", 6, 0)
    name:SetText(macroData.name)
    name:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Check for existing binding - just set border color (no text like spells)
    local bindings = CC:GetBindingsForMacro(macroData.id)
    if #bindings > 0 then
        row:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.8)
    end
    
    row.macroData = macroData
    row.existingBindings = bindings
    
    -- Sync warning for imports
    if (macroData.source == "global_import" or macroData.source == "char_import") and CC:IsMacroOutOfSync(macroData.id) then
        local syncIcon = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        syncIcon:SetPoint("RIGHT", -8, 0)
        syncIcon:SetText("!")
        syncIcon:SetTextColor(1, 0.8, 0)
    end
    
    -- Hover effects
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_ELEMENT.r + 0.08, C_ELEMENT.g + 0.08, C_ELEMENT.b + 0.08, 1)
        
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(macroData.name, 1, 1, 1)
        if macroData.source == "global_import" then
            GameTooltip:AddLine(L["General Import"], 0.6, 0.8, 1)
        elseif macroData.source == "char_import" then
            GameTooltip:AddLine(L["Character Import"], 0.8, 0.6, 1)
        else
            GameTooltip:AddLine(L["Custom Macro"], 0.6, 1, 0.6)
        end
        
        -- Show existing bindings in tooltip
        local myBindings = self.existingBindings
        if myBindings and #myBindings > 0 then
            GameTooltip:AddLine(" ")
            local bindStrs = {}
            for _, b in ipairs(myBindings) do
                table.insert(bindStrs, CC:GetBindingKeyText(b, true))
            end
            GameTooltip:AddLine(format(L["Bound: %s"], table.concat(bindStrs, ", ")), themeColor.r, themeColor.g, themeColor.b)
        end
        
        GameTooltip:AddLine(" ")
        local bodyPreview = macroData.body or ""
        if #bodyPreview > 100 then
            bodyPreview = bodyPreview:sub(1, 100) .. "..."
        end
        GameTooltip:AddLine(bodyPreview, 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Left-click: Bind"], 0.5, 0.5, 0.5)
        GameTooltip:AddLine(L["Right-click: Edit/View"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        GameTooltip:Hide()
    end)
    
    row:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            CC:ShowKeybindPopupForMacro(macroData)
        elseif button == "RightButton" then
            CC:ShowMacroEditorDialog(macroData)
        end
    end)
    
    return row
end

-- Show keybind popup for a macro
function CC:ShowKeybindPopupForMacro(macroData)
    if not macroData then return end
    
    local macroInfo = {
        name = macroData.name,
        icon = macroData.icon or "Interface\\Icons\\INV_Misc_QuestionMark",
        isMacro = true,
        macroId = macroData.id,
    }
    
    if self.db.options.quickBindEnabled then
        -- Quick bind mode - show simple keybind popup
        self.pendingMacroBinding = macroData
        self:ShowKeybindPopup(macroInfo)
    else
        -- Full edit mode - show edit binding panel
        self:ShowEditBindingPanel(macroInfo, nil, nil)
    end
end

-- Create a list row for a spell
function CC:CreateSpellListRow(parent, spellData, index, isSpecialAction, actionType)
    local themeColor = CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    local specialColor = {r = 0.6, g = 0.6, b = 0.9}
    
    local containerWidth = self.gridContainer:GetWidth() - 35
    local rowHeight = 28
    
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(containerWidth, rowHeight)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    
    if isSpecialAction then
        row:SetBackdropColor(specialColor.r * 0.15, specialColor.g * 0.15, specialColor.b * 0.15, 0.8)
        row:SetBackdropBorderColor(specialColor.r * 0.5, specialColor.g * 0.5, specialColor.b * 0.5, 0.8)
    else
        row:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.8)
        row:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    end
    row:RegisterForClicks("AnyDown")
    
    -- Get display info - use displayName from spell data if available (already has override applied)
    local displayName, displayIcon, displaySpellId
    if not isSpecialAction and spellData.spellId then
        -- Always get displaySpellId from GetSpellDisplayInfo for proper override detection
        displayName, displayIcon, displaySpellId = GetSpellDisplayInfo(spellData.spellId, spellData.name)
        
        -- Use displayName from spell data if available (already has override applied)
        if spellData.displayName then
            displayName = spellData.displayName
        end
        if spellData.icon then
            displayIcon = spellData.icon
        end
    else
        displayName = spellData.name
        displayIcon = spellData.icon
        displaySpellId = spellData.spellId
    end
    
    -- Icon (use current display icon)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("LEFT", 6, 0)
    icon:SetSize(22, 22)
    icon:SetTexture(displayIcon or spellData.icon)
    if not isSpecialAction then
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    
    -- Name (use current display name)
    local name = row:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetText(displayName or spellData.name)
    if isSpecialAction then
        name:SetTextColor(specialColor.r, specialColor.g, specialColor.b)
    else
        name:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    end
    
    -- Check for existing binding - just set border color, no text display
    -- Pass displaySpellId to match bindings that resolve to the same displayed spell
    local existingBindings
    if isSpecialAction then
        existingBindings = CC:GetBindingsForAction(actionType)
    else
        existingBindings = CC:GetBindingsForSpell(spellData.name, displaySpellId)
    end
    
    if #existingBindings > 0 then
        if isSpecialAction then
            row:SetBackdropBorderColor(specialColor.r, specialColor.g, specialColor.b, 1)
        else
            row:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
        end
    end
    
    row.spellData = spellData
    row.existingBindings = existingBindings
    row.isSpecialAction = isSpecialAction
    row.actionType = actionType
    row.displaySpellId = displaySpellId  -- Store for tooltip
    
    -- Hover effects
    row:SetScript("OnEnter", function(self)
        if isSpecialAction then
            self:SetBackdropColor(specialColor.r * 0.25, specialColor.g * 0.25, specialColor.b * 0.25, 1)
        else
            self:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
        end
        
        -- Tooltip (use current override spell ID for accurate tooltip)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if isSpecialAction then
            GameTooltip:SetText(spellData.name)
        else
            GameTooltip:SetSpellByID(self.displaySpellId or spellData.spellId)
        end
        
        -- Show existing bindings in tooltip if any
        local bindings = self.existingBindings
        if bindings and #bindings > 0 then
            GameTooltip:AddLine(" ")
            local bindStrs = {}
            for _, b in ipairs(bindings) do
                table.insert(bindStrs, CC:GetBindingKeyText(b, true))
            end
            local bindColor = isSpecialAction and specialColor or themeColor
            GameTooltip:AddLine(format(L["Bound: %s"], table.concat(bindStrs, ", ")), bindColor.r, bindColor.g, bindColor.b)
        end
        
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Left-click to add/edit binding"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    
    row:SetScript("OnLeave", function(self)
        if isSpecialAction then
            self:SetBackdropColor(specialColor.r * 0.15, specialColor.g * 0.15, specialColor.b * 0.15, 0.8)
        else
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.8)
        end
        GameTooltip:Hide()
    end)
    
    -- Click handler
    row:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            local info
            if isSpecialAction then
                info = {
                    actionType = actionType,
                    name = spellData.name,
                    icon = spellData.icon,
                }
            else
                info = {
                    spellName = spellData.name,
                    spellId = spellData.spellId,
                    name = spellData.name,
                    icon = spellData.icon,
                }
            end
            
            if CC.db.options.quickBindEnabled then
                -- Quick bind mode
                CC:ShowKeybindPopup(info)
            else
                -- Full edit mode
                CC:ShowEditBindingPanel(info, nil, nil)
            end
        end
    end)
    
    return row
end

function CC:CreateSpecialActionCell(parent, actionType, label, iconPath)
    local themeColor = CC.ACCENT
    local C_ELEMENT = DF.GUI.Colors.element
    local C_BORDER = DF.GUI.Colors.border
    local C_TEXT = DF.GUI.Colors.text
    local specialColor = {r = 0.6, g = 0.6, b = 0.9} -- Purple-ish for special actions
    
    local cellWidth = 85
    local cellHeight = 75
    
    local cell = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetSize(cellWidth, cellHeight)
    cell:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    cell:SetBackdropColor(specialColor.r * 0.15, specialColor.g * 0.15, specialColor.b * 0.15, 0.8)
    cell:SetBackdropBorderColor(specialColor.r * 0.5, specialColor.g * 0.5, specialColor.b * 0.5, 0.8)
    cell:RegisterForClicks("AnyDown")
    
    -- Icon (larger now)
    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOP", 0, -5)
    icon:SetSize(40, 40)
    icon:SetTexture(iconPath)
    
    -- Name
    local name = cell:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    name:SetPoint("TOP", icon, "BOTTOM", 0, -2)
    name:SetPoint("BOTTOM", 0, 3)
    name:SetWidth(cellWidth - 4)
    name:SetText(label)
    name:SetTextColor(specialColor.r, specialColor.g, specialColor.b)
    name:SetWordWrap(true)
    name:SetMaxLines(2)
    
    -- Check for existing binding - just set border, no text
    local existingBindings = {}
    for i, binding in ipairs(self.db.bindings) do
        if binding.actionType == actionType then
            table.insert(existingBindings, binding)
        end
    end
    
    if #existingBindings > 0 then
        cell:SetBackdropBorderColor(specialColor.r, specialColor.g, specialColor.b, 1)
    end
    
    cell.actionType = actionType
    cell.existingBindings = existingBindings
    
    -- Hover effects
    cell:SetScript("OnEnter", function(self)
        self:SetBackdropColor(specialColor.r * 0.4, specialColor.g * 0.4, specialColor.b * 0.4, 1)
        
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label)
        
        -- Show existing bindings in tooltip if any
        local bindings = self.existingBindings
        if bindings and #bindings > 0 then
            GameTooltip:AddLine(" ")
            local bindStrs = {}
            for _, b in ipairs(bindings) do
                table.insert(bindStrs, CC:GetBindingKeyText(b, true))
            end
            GameTooltip:AddLine(format(L["Bound: %s"], table.concat(bindStrs, ", ")), specialColor.r, specialColor.g, specialColor.b)
        end
        
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Left-click to add/edit binding"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    
    cell:SetScript("OnLeave", function(self)
        self:SetBackdropColor(specialColor.r * 0.15, specialColor.g * 0.15, specialColor.b * 0.15, 0.8)
        GameTooltip:Hide()
    end)
    
    -- Click handlers
    cell:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            local actionInfo = {
                actionType = actionType,
                name = label,
                icon = iconPath,
            }
            
            if CC.db.options.quickBindEnabled then
                -- Quick bind mode - show simple keybind popup
                CC:ShowKeybindPopup(actionInfo)
            else
                -- Full edit mode - show edit binding panel
                CC:ShowEditBindingPanel(actionInfo, nil, nil)
            end
        end
    end)
    
    return cell
end

-- Initialize when player enters world (deferred from ADDON_LOADED for faster load times)
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(self, event, isInitialLogin, isReloadingUi)
    -- Only initialize on first load or reload, not zone changes
    if isInitialLogin or isReloadingUi then
        CC:Initialize()
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end)

-- Debug slash command to list all detected spells
DF:RegisterDebugSlash("DFCCSPELLS", "Spellbook detection dump", true, "/dfccspells")
SlashCmdList["DFCCSPELLS"] = function(msg)
    if msg == "raw" then
        -- Dump raw spellbook data with item types
        print("|cff00ff00DandersFrames:|r Raw spellbook dump:")
        local bookType = Enum.SpellBookSpellBank.Player
        local numTabs = C_SpellBook.GetNumSpellBookSkillLines()
        
        -- Map item types to names
        local typeNames = {
            [Enum.SpellBookItemType.Spell] = "Spell",
            [Enum.SpellBookItemType.FutureSpell] = "FutureSpell",
            [Enum.SpellBookItemType.PetAction] = "PetAction",
            [Enum.SpellBookItemType.Flyout] = "Flyout",
        }
        
        for tabIndex = 1, numTabs do
            local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(tabIndex)
            if skillLineInfo and not skillLineInfo.shouldHide then
                local offset = skillLineInfo.itemIndexOffset
                local numSlots = skillLineInfo.numSpellBookItems
                local tabName = skillLineInfo.name or "Unknown"
                
                print("|cff00ff00Tab: " .. tabName .. "|r (" .. numSlots .. " slots)")
                
                for i = 1, numSlots do
                    local slotIndex = offset + i
                    local spellBookItemInfo = C_SpellBook.GetSpellBookItemInfo(slotIndex, bookType)
                    
                    if spellBookItemInfo then
                        local itemType = spellBookItemInfo.itemType
                        local spellId = spellBookItemInfo.spellID
                        local typeName = typeNames[itemType] or ("Unknown:" .. tostring(itemType))
                        local isPassive = C_SpellBook.IsSpellBookItemPassive(slotIndex, bookType)
                        local isKnown = spellId and C_SpellBook.IsSpellInSpellBook and 
                            C_SpellBook.IsSpellInSpellBook(spellId, bookType, true)
                        
                        local spellName = "?"
                        if spellId then
                            local spellInfo = C_Spell.GetSpellInfo(spellId)
                            if spellInfo then
                                spellName = spellInfo.name
                            end
                        end
                        
                        local flags = ""
                        if isPassive then flags = flags .. " [Passive]" end
                        if not isKnown then flags = flags .. " [NotKnown]" end
                        
                        print("  " .. typeName .. ": " .. spellName .. " (ID:" .. (spellId or "nil") .. ")" .. flags)
                    end
                end
            end
        end
    elseif msg == "types" then
        -- Just show counts by type
        print("|cff00ff00DandersFrames:|r Spell counts by type:")
        local bookType = Enum.SpellBookSpellBank.Player
        local numTabs = C_SpellBook.GetNumSpellBookSkillLines()
        local typeCounts = {}
        local notKnownCount = 0
        local passiveCount = 0
        
        for tabIndex = 1, numTabs do
            local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(tabIndex)
            if skillLineInfo and not skillLineInfo.shouldHide then
                local offset = skillLineInfo.itemIndexOffset
                local numSlots = skillLineInfo.numSpellBookItems
                
                for i = 1, numSlots do
                    local slotIndex = offset + i
                    local spellBookItemInfo = C_SpellBook.GetSpellBookItemInfo(slotIndex, bookType)
                    
                    if spellBookItemInfo then
                        local itemType = spellBookItemInfo.itemType
                        typeCounts[itemType] = (typeCounts[itemType] or 0) + 1
                        
                        local spellId = spellBookItemInfo.spellID
                        if spellId and C_SpellBook.IsSpellInSpellBook and 
                            not C_SpellBook.IsSpellInSpellBook(spellId, bookType, true) then
                            notKnownCount = notKnownCount + 1
                        end
                        if C_SpellBook.IsSpellBookItemPassive(slotIndex, bookType) then
                            passiveCount = passiveCount + 1
                        end
                    end
                end
            end
        end
        
        local typeNames = {
            [Enum.SpellBookItemType.Spell] = "Spell",
            [Enum.SpellBookItemType.FutureSpell] = "FutureSpell", 
            [Enum.SpellBookItemType.PetAction] = "PetAction",
            [Enum.SpellBookItemType.Flyout] = "Flyout",
        }
        
        for itemType, count in pairs(typeCounts) do
            local name = typeNames[itemType] or ("Unknown:" .. tostring(itemType))
            print("  " .. name .. ": " .. count)
        end
        print("  Passive: " .. passiveCount)
        print("  NotKnown: " .. notKnownCount)
        
    elseif msg == "list" then
        local spells = CC:GetAllPlayerSpells()
        local byCategory = {}
        for _, spell in ipairs(spells) do
            local cat = spell.tabName or "Unknown"
            if not byCategory[cat] then
                byCategory[cat] = {}
            end
            table.insert(byCategory[cat], spell.name)
        end
        
        for cat, names in pairs(byCategory) do
            print("|cff00ff00" .. cat .. ":|r " .. #names .. " spells")
            for _, name in ipairs(names) do
                print("  - " .. name)
            end
        end
    else
        local spells = CC:GetAllPlayerSpells()
        print("|cff00ff00DandersFrames:|r Found " .. #spells .. " spells")
        print("Commands:")
        print("  |cff00ff00/dfccspells list|r - Show included spells by category")
        print("  |cff00ff00/dfccspells types|r - Show counts by spell type")
        print("  |cff00ff00/dfccspells raw|r - Dump all spellbook entries with types")
    end
end

-- ============================================================
