local addonName, DF = ...

-- ============================================================
-- WIZARD BUILDER
-- Visual tool for creating, editing, and sharing setup wizards.
-- Stores wizard configs in DandersFramesDB_v2.wizardConfigs.
-- ============================================================

local pairs, ipairs, tinsert, tremove, wipe = pairs, ipairs, tinsert, tremove, wipe
local format = string.format
local type = type
local time = time
local L = DF.L

local WB = {}
DF.WizardBuilder = WB

-- ============================================================
-- WIZARD CONFIG HELPERS
-- ============================================================

local function GetWizardConfigs()
    return DandersFramesDB_v2 and DandersFramesDB_v2.wizardConfigs or {}
end

local function SaveWizardConfig(name, config)
    if not DandersFramesDB_v2 then return end
    if not DandersFramesDB_v2.wizardConfigs then DandersFramesDB_v2.wizardConfigs = {} end
    DandersFramesDB_v2.wizardConfigs[name] = config
end

local function CreateNewWizard(name)
    local config = {
        name = name,
        author = UnitName("player") or "Unknown",
        description = "",
        version = 1,
        created = time(),
        modified = time(),
        title = name,
        width = 440,
        steps = {
            {
                id = "step1",
                question = L["First question"],
                description = "",
                type = "single",
                options = {
                    { label = L["Option A"], value = "a" },
                    { label = L["Option B"], value = "b" },
                },
                next = "summary",
            },
            {
                id = "summary",
                type = "summary",
            },
        },
        settingsMap = {},
    }
    SaveWizardConfig(name, config)
    return config
end

-- ============================================================
-- IMPORT / EXPORT
-- Uses same LibSerialize + LibDeflate pattern as profiles
-- Format prefix: !DFW1!
-- ============================================================

local LibSerialize = LibStub("LibSerialize", true)
local LibDeflate = LibStub("LibDeflate", true)


function WB:ImportWizard(str)
    if not str or str == "" then return nil, "Empty string" end
    if not LibSerialize or not LibDeflate then return nil, "Missing libraries" end

    local prefix = str:sub(1, 6)
    if prefix ~= "!DFW1!" then return nil, "Invalid format (expected !DFW1! prefix)" end

    local encoded = str:sub(7)
    local compressed = LibDeflate:DecodeForPrint(encoded)
    if not compressed then return nil, "Decode failed" end

    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return nil, "Decompress failed" end

    local success, data = LibSerialize:Deserialize(serialized)
    if not success or not data then return nil, "Deserialize failed" end

    -- Validate basic structure
    if not data.name or not data.steps or type(data.steps) ~= "table" then
        return nil, "Invalid wizard structure"
    end

    return data
end

-- ============================================================
-- PREVIEW: Build a ShowPopupWizard config from stored data
-- ============================================================

-- Expose as both local and module function for Options.lua access
local function BuildWizardConfig(config)
    if not config then return nil end

    -- Deep copy steps to avoid modifying the stored config
    local steps = DF:DeepCopy(config.steps)

    -- For user-built wizards, branching is handled by EvaluateBranches in Popup.lua
    -- which reads step.branches directly. No function conversion needed.

    return {
        title = config.title or config.name or L["Wizard"],
        width = config.width or 440,
        steps = steps,
        settingsMap = config.settingsMap,
        onComplete = function(answers)
            -- settingsMap is applied automatically by CompleteWizard() in Popup.lua
            DF:Debug("Wizard '" .. (config.name or "?") .. "' completed")
        end,
    }
end

-- ============================================================
-- STATE: Track which wizard and step are being edited
-- ============================================================

local editingWizardName = nil
local editingStepIndex = nil

-- ============================================================
-- BUILDER POPUP
-- A popup-style editor that looks like the wizard output but
-- with editable fields. Each "page" edits one wizard step.
-- ============================================================

local BuilderFrame = nil
local builderConfig = nil       -- The wizard config being edited
local builderWizardName = nil   -- Name key in SavedVariables
local builderStepIndex = 1      -- Which step is currently shown
local builderOnSave = nil       -- Callback when wizard is saved

-- The shared dialog palette, same one Popup.lua uses. This was a complete
-- private copy of all eleven colours, "matching Popup.lua" by hand -- so it
-- matched only until either side moved.
local BC = DF.GUI.DialogColors

local BUILDER_WIDTH = 500
local BUILDER_PADDING = 20

-- Thin wrapper over the shared GUI backdrop so this file's positional call style
-- keeps working. The look, and the pixel-grid snapping, come from the one place.
local function ApplyBuilderBackdrop(frame, bgColor, borderColor, edgeSize)
    DF.GUI:CreateElementBackdrop(frame, {
        bgColor     = bgColor,
        borderColor = borderColor,
        edgeSize    = edgeSize,
    })
end

-- Create an edit box with dark theme styling
local function CreateBuilderEditBox(parent, width, height, multiLine)
    -- Use a container frame with backdrop, edit box inside it
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(width, height)
    ApplyBuilderBackdrop(container, BC.element, BC.border, 1)
    container:SetBackdropColor(0, 0, 0, 0.5)
    container:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    local edit = CreateFrame("EditBox", nil, container)
    edit:SetPoint("TOPLEFT", 8, -4)
    edit:SetPoint("BOTTOMRIGHT", -8, 4)
    edit:SetAutoFocus(false)
    edit:SetFontObject(DFFontHighlightSmall)
    edit:SetTextColor(BC.text.r, BC.text.g, BC.text.b)
    if multiLine then
        edit:SetMultiLine(true)
        edit:SetMaxLetters(500)
    end
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Forward common methods to the container for positioning
    container.SetText = function(_, text) edit:SetText(text or "") end
    container.GetText = function(_) return edit:GetText() end
    container.SetScript = function(_, event, handler)
        if event == "OnEnterPressed" or event == "OnEscapePressed" or event == "OnTextChanged" then
            edit:SetScript(event, handler)
        end
    end
    container.ClearFocus = function(_) edit:ClearFocus() end
    container.editBox = edit

    return container
end

-- Create a themed button
local function CreateBuilderButton(parent, text, width, height, onClick)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    DF.GUI:StyleButton(btn, { width = width, height = height, text = text })

    btn:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if onClick then onClick() end
    end)
    return btn
end

-- Create a small icon button (delete, settings, branch)
local function CreateSmallButton(parent, text, size, onClick, color)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(size, size)
    local bgColor = color or BC.element
    ApplyBuilderBackdrop(btn, bgColor, BC.border, 1)

    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    btn.Text:SetPoint("CENTER")
    btn.Text:SetText(text)

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(BC.hover.r, BC.hover.g, BC.hover.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        ApplyBuilderBackdrop(self, bgColor, BC.border, 1)
    end)
    btn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if onClick then onClick() end
    end)
    return btn
end

-- Pool of option row frames for reuse
local optionRowPool = {}

local function GetOptionRow()
    local row = tremove(optionRowPool)
    if row then
        row:Show()
        return row
    end
    return nil  -- Caller will create new
end

local function ReleaseOptionRow(row)
    row:Hide()
    row:ClearAllPoints()
    row:SetParent(UIParent)
    tinsert(optionRowPool, row)
end

-- Active option rows in current render
local activeOptionRows = {}

local function SaveCurrentConfig()
    if builderWizardName and builderConfig then
        builderConfig.modified = time()
        SaveWizardConfig(builderWizardName, builderConfig)
    end
end

-- ============================================================
-- BUILDER FRAME CONSTRUCTION
-- ============================================================

local function CreateBuilderFrame()
    if BuilderFrame then return BuilderFrame end

    local f = CreateFrame("Frame", "DFBuilderFrame", UIParent, "BackdropTemplate")
    -- Ride the shared GUI pixel grid: this surface is parented to UIParent, so it
    -- never passes through a settings-page build. See GUI:AttachPixelSnap.
    if DF.GUI and DF.GUI.AttachPixelSnap then DF.GUI:AttachPixelSnap(f) end
    f:SetSize(BUILDER_WIDTH, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(200)
    ApplyBuilderBackdrop(f, BC.background, BC.border, 2)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:Hide()

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT", 2, -2)
    titleBar:SetPoint("TOPRIGHT", -2, -2)
    titleBar:SetHeight(32)
    ApplyBuilderBackdrop(titleBar, BC.panel, BC.border, 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f.TitleBar = titleBar

    -- Accent stripe
    local accent = f:CreateTexture(nil, "OVERLAY")
    accent:SetPoint("TOPLEFT", 0, 0)
    accent:SetPoint("TOPRIGHT", 0, 0)
    accent:SetHeight(2)
    accent:SetColorTexture(BC.accent.r, BC.accent.g, BC.accent.b, 1)
    f.AccentStripe = accent

    -- Title text
    f.TitleText = titleBar:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    f.TitleText:SetPoint("CENTER")
    f.TitleText:SetText(L["Wizard Builder"])
    f.TitleText:SetTextColor(BC.text.r, BC.text.g, BC.text.b)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", -6, 0)
    closeBtn.bg = closeBtn:CreateTexture(nil, "BACKGROUND")
    closeBtn.bg:SetAllPoints()
    closeBtn.bg:SetColorTexture(BC.red.r, BC.red.g, BC.red.b, 0.8)
    closeBtn.text = closeBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    closeBtn.text:SetPoint("CENTER", 0, 1)
    closeBtn.text:SetText("x")
    closeBtn:SetScript("OnClick", function()
        SaveCurrentConfig()
        f:Hide()
    end)
    closeBtn:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(1, 0.3, 0.3, 1)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(BC.red.r, BC.red.g, BC.red.b, 0.8)
    end)

    -- Content area (plain frame, no scroll — frame resizes to fit)
    local contentArea = CreateFrame("Frame", nil, f)
    contentArea:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    contentArea:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    -- Bottom will be set dynamically when we know content height
    contentArea:SetHeight(400)
    f.Content = contentArea

    -- Button bar
    local buttonBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    buttonBar:SetPoint("BOTTOMLEFT", 2, 2)
    buttonBar:SetPoint("BOTTOMRIGHT", -2, 2)
    buttonBar:SetHeight(44)
    ApplyBuilderBackdrop(buttonBar, BC.panel, BC.border, 1)
    f.ButtonBar = buttonBar

    -- Back button
    f.BackBtn = CreateBuilderButton(buttonBar, L["Back"], 90, 30, function()
        if builderStepIndex > 1 then
            builderStepIndex = builderStepIndex - 1
            RenderBuilderStep()
        end
    end)
    f.BackBtn:SetPoint("LEFT", 10, 0)

    -- Add Step button (center)
    f.AddStepBtn = CreateBuilderButton(buttonBar, L["+ Add Step"], 100, 30, function()
        if not builderConfig then return end
        -- Insert new step after current (before summary if exists)
        local insertPos = builderStepIndex + 1
        -- Don't insert after summary
        if builderConfig.steps[builderStepIndex] and builderConfig.steps[builderStepIndex].type == "summary" then
            insertPos = builderStepIndex
        end
        local newId = "step" .. (#builderConfig.steps + 1)
        tinsert(builderConfig.steps, insertPos, {
            id = newId,
            question = "",
            description = "",
            type = "single",
            options = {
                { label = L["Option A"], value = "a" },
                { label = L["Option B"], value = "b" },
            },
        })
        SaveCurrentConfig()
        builderStepIndex = insertPos
        RenderBuilderStep()
    end)
    f.AddStepBtn:SetPoint("CENTER", 0, 0)

    -- Next/Save button
    f.NextBtn = CreateBuilderButton(buttonBar, L["Next"], 90, 30, function()
        if not builderConfig then return end
        if builderStepIndex < #builderConfig.steps then
            builderStepIndex = builderStepIndex + 1
            RenderBuilderStep()
        else
            -- Last step: save and close
            SaveCurrentConfig()
            f:Hide()
            if builderOnSave then builderOnSave(builderWizardName) end
        end
    end)
    f.NextBtn:SetPoint("RIGHT", -10, 0)

    -- Progress dots container
    f.DotsContainer = CreateFrame("Frame", nil, f)
    f.DotsContainer:SetHeight(12)
    f.DotsContainer:SetPoint("BOTTOM", buttonBar, "TOP", 0, 4)
    f.Dots = {}

    -- Add to special frames for Escape key
    tinsert(UISpecialFrames, "DFBuilderFrame")

    BuilderFrame = f
    return f
end

-- ============================================================
-- RENDER A BUILDER STEP
-- Shows editable fields for one step of the wizard
-- ============================================================

local function UpdateBuilderDots()
    if not BuilderFrame or not builderConfig then return end
    local numSteps = #builderConfig.steps
    local dots = BuilderFrame.Dots
    local dotSize = 8
    local dotSpacing = 6
    local totalWidth = numSteps * dotSize + (numSteps - 1) * dotSpacing

    BuilderFrame.DotsContainer:SetWidth(totalWidth)

    for i = 1, max(numSteps, #dots) do
        if i <= numSteps then
            if not dots[i] then
                dots[i] = BuilderFrame.DotsContainer:CreateTexture(nil, "OVERLAY")
                dots[i]:SetSize(dotSize, dotSize)
            end
            dots[i]:ClearAllPoints()
            dots[i]:SetPoint("LEFT", (i - 1) * (dotSize + dotSpacing), 0)
            if i == builderStepIndex then
                dots[i]:SetColorTexture(BC.accent.r, BC.accent.g, BC.accent.b, 1)
            else
                dots[i]:SetColorTexture(BC.border.r, BC.border.g, BC.border.b, 1)
            end
            dots[i]:Show()
        elseif dots[i] then
            dots[i]:Hide()
        end
    end
end

local function UpdateBuilderNavButtons()
    if not BuilderFrame or not builderConfig then return end

    -- Back
    if builderStepIndex > 1 then
        BuilderFrame.BackBtn:Show()
    else
        BuilderFrame.BackBtn:Hide()
    end

    -- Next/Save
    if builderStepIndex >= #builderConfig.steps then
        BuilderFrame.NextBtn.Text:SetText(L["Save & Close"])
    else
        BuilderFrame.NextBtn.Text:SetText(L["Next"])
    end
end

-- Forward declaration
-- RenderBuilderStep defined below after helpers

local function ClearBuilderContent()
    -- Release option rows
    for _, row in ipairs(activeOptionRows) do
        ReleaseOptionRow(row)
    end
    wipe(activeOptionRows)

    -- Destroy the inner content container and recreate it
    -- This ensures ALL children AND font strings are removed
    if BuilderFrame and BuilderFrame.ContentInner then
        BuilderFrame.ContentInner:Hide()
        BuilderFrame.ContentInner:SetParent(nil)
    end

    if BuilderFrame and BuilderFrame.Content then
        local inner = CreateFrame("Frame", nil, BuilderFrame.Content)
        inner:SetAllPoints()
        BuilderFrame.ContentInner = inner
    end
end

-- Create an option row for the builder
local function CreateOptionRowFrame(parent, optIndex, step, onUpdate)
    local row = GetOptionRow()
    if not row then
        row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        row:SetHeight(32)
        ApplyBuilderBackdrop(row, {r = 0.14, g = 0.14, b = 0.14, a = 1}, BC.border, 1)

        -- Label edit box
        row.LabelEdit = CreateFrame("EditBox", nil, row, "BackdropTemplate")
        row.LabelEdit:SetHeight(24)
        row.LabelEdit:SetPoint("LEFT", 8, 0)
        row.LabelEdit:SetAutoFocus(false)
        row.LabelEdit:SetFontObject(DFFontHighlightSmall)
        row.LabelEdit:SetTextInsets(6, 6, 0, 0)
        DF.GUI:StyleEditBox(row.LabelEdit, { skipFont = true })
        row.LabelEdit:SetTextColor(BC.text.r, BC.text.g, BC.text.b)
        row.LabelEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        -- Delete button (rightmost)
        row.DeleteBtn = CreateSmallButton(row, "x", 24, nil, BC.element)
        row.DeleteBtn:SetPoint("RIGHT", -4, 0)
        row.DeleteBtn.Text:SetTextColor(BC.red.r, BC.red.g, BC.red.b)

        -- Branch button (wider to show step IDs)
        row.BranchBtn = CreateSmallButton(row, "->", 24, nil, BC.element)
        row.BranchBtn:SetSize(70, 24)
        row.BranchBtn:SetPoint("RIGHT", row.DeleteBtn, "LEFT", -2, 0)
        row.BranchBtn.Text:SetTextColor(BC.accent.r, BC.accent.g, BC.accent.b)
        row.BranchBtn.Text:SetFontObject(DFFontHighlightSmall)

        -- Settings gear button
        row.GearBtn = CreateSmallButton(row, "S", 24, nil, BC.element)
        row.GearBtn:SetPoint("RIGHT", row.BranchBtn, "LEFT", -2, 0)
        row.GearBtn.Text:SetTextColor(BC.orange.r, BC.orange.g, BC.orange.b)
    end

    row:SetParent(parent)
    row.LabelEdit:ClearAllPoints()
    row.LabelEdit:SetPoint("LEFT", 8, 0)
    row.LabelEdit:SetPoint("RIGHT", row.GearBtn, "LEFT", -8, 0)

    -- Configure for this option
    local opt = step.options[optIndex]
    row.LabelEdit:SetText(opt and opt.label or "")
    row.LabelEdit:SetScript("OnTextChanged", function(self)
        if step.options[optIndex] then
            step.options[optIndex].label = self:GetText()
            step.options[optIndex].value = self:GetText():gsub("%s+", "_"):lower()
            SaveCurrentConfig()
        end
    end)
    row.LabelEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Gear: open settings picker for this option
    row.GearBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if not step.options[optIndex] then return end
        local optValue = step.options[optIndex].value
        -- Hide builder, enter picker mode
        BuilderFrame:Hide()
        DF:EnterSettingsPickerMode(function(tabName, dbKey, controlType)
            local currentValue = DF:GetDBKeyByPath(DF.GUI.SelectedMode .. "." .. dbKey)
            local mode = DF.GUI.SelectedMode or "party"
            local fullKey = mode .. "." .. dbKey

            -- Helper to store a setting value and return to builder
            local function LinkSettingValue(setValue)
                if not builderConfig.settingsMap then builderConfig.settingsMap = {} end
                if not builderConfig.settingsMap[step.id] then builderConfig.settingsMap[step.id] = {} end
                if not builderConfig.settingsMap[step.id][optValue] then builderConfig.settingsMap[step.id][optValue] = {} end
                builderConfig.settingsMap[step.id][optValue][fullKey] = setValue
                SaveCurrentConfig()
                BuilderFrame:Show()
                RenderBuilderStep()
            end

            -- Helper to store as highlight
            local function LinkSettingHighlight()
                if not step.highlightSettings then step.highlightSettings = {} end
                local found = false
                for _, k in ipairs(step.highlightSettings) do
                    if k == dbKey then found = true break end
                end
                if not found then
                    tinsert(step.highlightSettings, dbKey)
                end
                step.openTab = tabName
                SaveCurrentConfig()
                BuilderFrame:Show()
                RenderBuilderStep()
            end

            -- Build action buttons based on control type
            if controlType == "checkbox" then
                -- Checkbox: offer true/false choice
                DF:ShowPopupWizard({
                    title = format(L["Link: %s"], dbKey),
                    width = 400,
                    steps = {
                        {
                            id = "action",
                            question = format(L["What should '%s' do with this setting?"], (opt and opt.label or L["this option"])),
                            description = format(L["%s (currently %s)"], dbKey, tostring(currentValue)),
                            type = "single",
                            options = {
                                { label = L["Enable (set to true)"], value = "set_true" },
                                { label = L["Disable (set to false)"], value = "set_false" },
                                { label = L["Highlight for user to configure"], value = "highlight" },
                            },
                        },
                    },
                    onComplete = function(answers)
                        local action = answers.action
                        if action == "set_true" then
                            LinkSettingValue(true)
                        elseif action == "set_false" then
                            LinkSettingValue(false)
                        elseif action == "highlight" then
                            LinkSettingHighlight()
                        else
                            BuilderFrame:Show()
                        end
                    end,
                    onCancel = function()
                        BuilderFrame:Show()
                    end,
                })
            elseif controlType == "slider" then
                -- Slider: show current value and let user type a number
                DF:ShowPopupAlert({
                    title = format(L["Link: %s"], dbKey),
                    message = format(L["Setting: %s\nCurrent value: %s\n\nEnter the value to set, or highlight for the user."],
                        dbKey, tostring(currentValue)),
                    buttons = {
                        {
                            label = format(L["Use Current (%s)"], tostring(currentValue)),
                            onClick = function()
                                LinkSettingValue(currentValue)
                            end,
                        },
                        {
                            label = L["Highlight for User"],
                            onClick = function()
                                LinkSettingHighlight()
                            end,
                        },
                        {
                            label = L["Cancel"],
                            onClick = function()
                                BuilderFrame:Show()
                            end,
                        },
                    },
                })
            else
                -- Dropdown/color/other: offer highlight or use current value
                DF:ShowPopupAlert({
                    title = format(L["Link: %s"], dbKey),
                    message = format(L["Setting: %s\nCurrent value: %s\n\nWhat should happen when '%s' is selected?"],
                        dbKey, tostring(currentValue), opt and opt.label or L["this option"]),
                    buttons = {
                        {
                            label = L["Use Current Value"],
                            onClick = function()
                                LinkSettingValue(currentValue)
                            end,
                        },
                        {
                            label = L["Highlight for User"],
                            onClick = function()
                                LinkSettingHighlight()
                            end,
                        },
                        {
                            label = L["Cancel"],
                            onClick = function()
                                BuilderFrame:Show()
                            end,
                        },
                    },
                })
            end  -- if controlType
        end)  -- EnterSettingsPickerMode callback
    end)  -- GearBtn OnClick

    -- Branch: cycle through available steps
    row.BranchBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if not step.options[optIndex] or not builderConfig then return end
        -- Build list of step IDs to cycle through
        local stepIds = {}
        for _, s in ipairs(builderConfig.steps) do
            if s.id ~= step.id then
                tinsert(stepIds, s.id)
            end
        end
        tinsert(stepIds, "")  -- Empty = no branch (follow default next)

        -- Find current branch for this option
        if not step.branches then step.branches = {} end
        local currentGoto = ""
        for _, b in ipairs(step.branches) do
            if b.condition and b.condition.equals == step.options[optIndex].value then
                currentGoto = b["goto"] or ""
                break
            end
        end

        -- Cycle to next
        local nextIdx = 1
        for i, id in ipairs(stepIds) do
            if id == currentGoto then
                nextIdx = (i % #stepIds) + 1
                break
            end
        end
        local newGoto = stepIds[nextIdx]

        -- Update or create branch
        local found = false
        for _, b in ipairs(step.branches) do
            if b.condition and b.condition.equals == step.options[optIndex].value then
                if newGoto == "" then
                    -- Remove branch
                    for j, bb in ipairs(step.branches) do
                        if bb == b then tremove(step.branches, j) break end
                    end
                else
                    b["goto"] = newGoto
                end
                found = true
                break
            end
        end
        if not found and newGoto ~= "" then
            tinsert(step.branches, {
                condition = { equals = step.options[optIndex].value },
                ["goto"] = newGoto,
            })
        end
        SaveCurrentConfig()
        -- Re-render to show updated branch display
        RenderBuilderStep()
    end)

    -- Update branch display
    local branchTarget = ""
    if step.branches then
        for _, b in ipairs(step.branches) do
            if b.condition and b.condition.equals == (opt and opt.value) then
                branchTarget = b["goto"] or ""
                break
            end
        end
    end
    if branchTarget ~= "" then
        row.BranchBtn.Text:SetText("> " .. branchTarget)
    else
        row.BranchBtn.Text:SetText(L["no branch"])
    end

    -- Delete
    row.DeleteBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if #step.options > 1 then
            tremove(step.options, optIndex)
            SaveCurrentConfig()
            RenderBuilderStep()
        end
    end)

    -- Tooltip for gear showing linked settings
    row.GearBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(BC.hover.r, BC.hover.g, BC.hover.b, 1)
        local linked = {}
        local sm = builderConfig.settingsMap
        if sm and sm[step.id] and opt and sm[step.id][opt.value] then
            for k, v in pairs(sm[step.id][opt.value]) do
                tinsert(linked, k .. " = " .. tostring(v))
            end
        end
        if #linked > 0 then
            local lines = {}
            for _, line in ipairs(linked) do
                lines[#lines + 1] = { text = line, color = BC.orange }
            end
            DF.GUI:ShowTooltip(self, { title = L["Linked Settings"], lines = lines })
        end
    end)
    row.GearBtn:SetScript("OnLeave", function(self)
        ApplyBuilderBackdrop(self, BC.element, BC.border, 1)
        GameTooltip:Hide()
    end)

    -- Tooltip for branch
    row.BranchBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(BC.hover.r, BC.hover.g, BC.hover.b, 1)
        DF.GUI:ShowTooltip(self, {
            title = L["Branch"],
            lines = {
                branchTarget ~= ""
                    and { text = format(L["Goes to: %s"], branchTarget), color = BC.accent }
                    or  { text = L["Click to set branch target"], hint = true },
                { text = L["Click to cycle through steps"], hint = true },
            },
        })
    end)
    row.BranchBtn:SetScript("OnLeave", function(self)
        ApplyBuilderBackdrop(self, BC.element, BC.border, 1)
        GameTooltip:Hide()
    end)

    row:Show()
    tinsert(activeOptionRows, row)
    return row
end

function RenderBuilderStep()
    if not BuilderFrame or not builderConfig then return end

    ClearBuilderContent()

    local step = builderConfig.steps[builderStepIndex]
    if not step then return end

    local parent = BuilderFrame.ContentInner or BuilderFrame.Content
    local y = -BUILDER_PADDING
    local contentWidth = BUILDER_WIDTH - 40

    -- Step counter + delete button
    local counterFrame = CreateFrame("Frame", nil, parent)
    counterFrame:SetSize(contentWidth, 24)
    counterFrame:SetPoint("TOPLEFT", BUILDER_PADDING, y)

    local counterText = counterFrame:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    counterText:SetPoint("LEFT")
    counterText:SetText(format(L["Step %d of %d"], builderStepIndex, #builderConfig.steps))
    counterText:SetTextColor(BC.textDim.r, BC.textDim.g, BC.textDim.b)

    -- Delete step button (only if more than 1 step)
    if #builderConfig.steps > 1 then
        local delStep = CreateBuilderButton(counterFrame, L["Delete Step"], 80, 20, function()
            tremove(builderConfig.steps, builderStepIndex)
            if builderStepIndex > #builderConfig.steps then
                builderStepIndex = #builderConfig.steps
            end
            SaveCurrentConfig()
            RenderBuilderStep()
        end)
        delStep:SetPoint("RIGHT")
        delStep.Text:SetTextColor(BC.red.r, BC.red.g, BC.red.b)
    end

    y = y - 32

    -- Wizard Name (editable, shown on first step only)
    if builderStepIndex == 1 then
        local nameLabel = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        nameLabel:SetPoint("TOPLEFT", BUILDER_PADDING, y)
        nameLabel:SetText(L["Wizard Name:"])
        nameLabel:SetTextColor(BC.textDim.r, BC.textDim.g, BC.textDim.b)
        y = y - 18

        local nameEdit = CreateBuilderEditBox(parent, contentWidth, 28)
        nameEdit:SetPoint("TOPLEFT", BUILDER_PADDING, y)
        nameEdit:SetText(builderConfig.title or builderConfig.name or "")
        nameEdit:SetScript("OnTextChanged", function(self)
            local newTitle = self:GetText()
            if newTitle and newTitle ~= "" then
                builderConfig.title = newTitle
                BuilderFrame.TitleText:SetText(L["Building: "] .. newTitle)
                SaveCurrentConfig()
            end
        end)
        nameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        y = y - 36
    end

    -- Summary step is special — no editable content
    if step.type == "summary" then
        local summaryLabel = parent:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
        summaryLabel:SetPoint("TOPLEFT", BUILDER_PADDING, y)
        summaryLabel:SetText(L["Summary Step"])
        summaryLabel:SetTextColor(BC.text.r, BC.text.g, BC.text.b)
        y = y - 30

        local desc = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        desc:SetPoint("TOPLEFT", BUILDER_PADDING, y)
        desc:SetPoint("RIGHT", parent, "RIGHT", -BUILDER_PADDING, 0)
        desc:SetText(L["This step automatically shows a review of all the user's answers. It's always the last step."])
        desc:SetTextColor(BC.textDim.r, BC.textDim.g, BC.textDim.b)
        desc:SetJustifyH("LEFT")
        desc:SetWordWrap(true)
        y = y - (desc:GetStringHeight() or 30) - 20

        local contentHeight = math.abs(y) + 20
        BuilderFrame.Content:SetHeight(contentHeight)
        local frameHeight = contentHeight + 32 + 44 + 24
        frameHeight = min(max(frameHeight, 300), 650)
        BuilderFrame:SetHeight(frameHeight)
        BuilderFrame.Content:ClearAllPoints()
        BuilderFrame.Content:SetPoint("TOPLEFT", BuilderFrame.TitleBar, "BOTTOMLEFT", 0, 0)
        BuilderFrame.Content:SetPoint("BOTTOMRIGHT", BuilderFrame.ButtonBar, "TOPRIGHT", 0, 16)
        UpdateBuilderDots()
        UpdateBuilderNavButtons()
        return
    end

    -- Step Type (simple label + cycle button)
    local typeLabel = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    typeLabel:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    typeLabel:SetText(L["Type:"])
    typeLabel:SetTextColor(BC.textDim.r, BC.textDim.g, BC.textDim.b)

    local typeNames = { single = L["Single Select"], multi = L["Multi Select"] }
    local typeBtn = CreateBuilderButton(parent, typeNames[step.type] or L["Single Select"], 120, 22, function()
        if step.type == "single" then
            step.type = "multi"
        else
            step.type = "single"
        end
        SaveCurrentConfig()
        RenderBuilderStep()
    end)
    typeBtn:SetPoint("LEFT", typeLabel, "RIGHT", 8, 0)
    y = y - 30

    -- Question
    local qLabel = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    qLabel:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    qLabel:SetText(L["Question:"])
    qLabel:SetTextColor(BC.textDim.r, BC.textDim.g, BC.textDim.b)
    y = y - 18

    local qEdit = CreateBuilderEditBox(parent, contentWidth, 28)
    qEdit:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    qEdit:SetText(step.question or "")
    qEdit:SetScript("OnTextChanged", function(self)
        step.question = self:GetText()
        SaveCurrentConfig()
    end)
    qEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    y = y - 36

    -- Description
    local dLabel = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    dLabel:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    dLabel:SetText(L["Description (optional)"])
    dLabel:SetTextColor(BC.textDim.r, BC.textDim.g, BC.textDim.b)
    y = y - 18

    local dEdit = CreateBuilderEditBox(parent, contentWidth, 56, true)
    dEdit:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    dEdit:SetText(step.description or "")
    dEdit:SetScript("OnTextChanged", function(self)
        step.description = self:GetText()
        SaveCurrentConfig()
    end)
    y = y - 64

    -- Options header
    local optLabel = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    optLabel:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    optLabel:SetText(L["Options:    [S] = Link Setting    [->] = Branch    [x] = Delete"])
    optLabel:SetTextColor(BC.textDim.r, BC.textDim.g, BC.textDim.b)
    y = y - 20

    -- Option rows
    if not step.options then step.options = {} end
    for i, opt in ipairs(step.options) do
        local row = CreateOptionRowFrame(parent, i, step, function()
            SaveCurrentConfig()
            RenderBuilderStep()
        end)
        row:SetPoint("TOPLEFT", BUILDER_PADDING, y)
        row:SetPoint("RIGHT", parent, "RIGHT", -BUILDER_PADDING, 0)
        y = y - 36
    end

    -- Add Option button
    local addOptBtn = CreateBuilderButton(parent, L["+ Add Option"], 120, 26, function()
        local newLabel = "Option " .. string.char(64 + #step.options + 1)  -- A, B, C...
        tinsert(step.options, { label = newLabel, value = newLabel:gsub("%s+", "_"):lower() })
        SaveCurrentConfig()
        RenderBuilderStep()
    end)
    addOptBtn:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    y = y - 36

    -- Integration section (collapsible)
    local intLabel = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    intLabel:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    intLabel:SetText(L["Integration (advanced):"])
    intLabel:SetTextColor(BC.textDim.r, BC.textDim.g, BC.textDim.b)
    y = y - 20

    -- Test mode toggle
    local testModes = { "", "party", "raid" }
    local testModeNames = { [""] = L["None"], party = L["Party"], raid = L["Raid"] }
    local testBtn = CreateBuilderButton(parent, format(L["Test Mode: %s"], testModeNames[step.testMode or ""]), 160, 22, function()
        local current = step.testMode or ""
        local nextIdx = 1
        for i, m in ipairs(testModes) do
            if m == current then nextIdx = (i % #testModes) + 1 break end
        end
        step.testMode = testModes[nextIdx] ~= "" and testModes[nextIdx] or nil
        SaveCurrentConfig()
        RenderBuilderStep()
    end)
    testBtn:SetPoint("TOPLEFT", BUILDER_PADDING, y)
    y = y - 28

    -- Open Tab info
    if step.openTab then
        local tabInfo = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        tabInfo:SetPoint("TOPLEFT", BUILDER_PADDING, y)
        tabInfo:SetText(format(L["Opens tab: %s"], step.openTab))
        tabInfo:SetTextColor(BC.orange.r, BC.orange.g, BC.orange.b)
        y = y - 18
    end

    -- Highlight Settings info
    if step.highlightSettings and #step.highlightSettings > 0 then
        local hlInfo = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        hlInfo:SetPoint("TOPLEFT", BUILDER_PADDING, y)
        hlInfo:SetText(format(L["Highlights: %s"], table.concat(step.highlightSettings, ", ")))
        hlInfo:SetTextColor(BC.orange.r, BC.orange.g, BC.orange.b)
        y = y - 18
    end

    y = y - 20

    -- Resize content area and frame to fit
    local contentHeight = math.abs(y) + 20
    BuilderFrame.Content:SetHeight(contentHeight)

    local frameHeight = contentHeight + 32 + 44 + 24  -- titlebar + buttonbar + dots
    frameHeight = min(max(frameHeight, 300), 650)
    BuilderFrame:SetHeight(frameHeight)

    -- Update content bottom anchor relative to button bar
    BuilderFrame.Content:ClearAllPoints()
    BuilderFrame.Content:SetPoint("TOPLEFT", BuilderFrame.TitleBar, "BOTTOMLEFT", 0, 0)
    BuilderFrame.Content:SetPoint("BOTTOMRIGHT", BuilderFrame.ButtonBar, "TOPRIGHT", 0, 16)

    UpdateBuilderDots()
    UpdateBuilderNavButtons()
end

-- ============================================================
-- PUBLIC API: Show the builder popup
-- ============================================================

function WB:ShowBuilder(wizardName, onSave)
    local configs = GetWizardConfigs()
    local config = configs[wizardName]
    if not config then
        config = CreateNewWizard(wizardName)
    end

    -- Ensure summary step exists at end
    local hasSummary = false
    for _, s in ipairs(config.steps) do
        if s.type == "summary" then hasSummary = true break end
    end
    if not hasSummary then
        tinsert(config.steps, { id = "summary", type = "summary" })
        SaveWizardConfig(wizardName, config)
    end

    builderConfig = config
    builderWizardName = wizardName
    builderStepIndex = 1
    builderOnSave = onSave

    local f = CreateBuilderFrame()
    -- Theme the accent to the current mode (party purple / raid orange) on each
    -- open. The frame is cached, so this must run here rather than at build time.
    -- RenderBuilderStep (below) reads BC.accent for the progress dots, so update
    -- it before rendering; the stripe is a build-once texture so recolour it too.
    local tc = DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor()
    if tc then
        BC.accent.r, BC.accent.g, BC.accent.b = tc.r, tc.g, tc.b
        if f.AccentStripe then f.AccentStripe:SetColorTexture(tc.r, tc.g, tc.b, 1) end
    end
    f.TitleText:SetText(L["Building: "] .. (config.title or wizardName))
    f:Show()
    RenderBuilderStep()
end

-- Expose for use in Options.lua
function DF:ShowWizardBuilder(wizardName, onSave)
    WB:ShowBuilder(wizardName, onSave)
end

-- ============================================================
-- PAGE: MY WIZARDS (List + Management)
-- ============================================================

-- ============================================================
-- PAGE: STEP EDITOR
-- ============================================================

-- ============================================================
-- MODULE EXPORTS
-- ============================================================

-- Expose BuildWizardConfig for Options.lua
WB.BuildWizardConfig = BuildWizardConfig

-- Built-in wizard registry
-- Each entry: { name, description, build = function() return wizard config end }
--
-- ⚠ CURRENTLY UNUSED, KEPT ON PURPOSE (reviewed 2026-07-25). Nothing anywhere calls
-- RegisterBuiltinWizard, so this list is permanently empty and GetBuiltinWizards()
-- always returns {} — which is why the Options > Wizards page always renders its
-- "No built-in wizards available yet. Check back after updates!" placeholder. The
-- rest of WizardBuilder is very much alive (user-created wizards, import/export,
-- the /df commands); it is only the BUILT-IN half that has never been populated.
--
-- Krathe's call: keep the framework, we may yet use it. If a later pass finds we
-- still have not shipped a single built-in wizard, delete this registry, the two
-- accessors, and the placeholder branch on the Wizards page together — and drop the
-- user-facing "check back after updates" promise with them, since it is the part
-- that actually costs us something while it stays unkept.
local builtinWizards = {}



-- Import wizard via slash command
function WB:HandleImportCommand(str)
    local data, err = self:ImportWizard(str)
    if not data then
        print("|cffff0000DandersFrames:|r Import failed: " .. (err or "unknown"))
        return
    end
    local name = data.name or "Imported Wizard"
    -- Avoid overwriting existing
    local configs = GetWizardConfigs()
    if configs[name] then
        local counter = 1
        while configs[name .. " " .. counter] do counter = counter + 1 end
        name = name .. " " .. counter
        data.name = name
    end
    SaveWizardConfig(name, data)
    print("|cff00ff00DandersFrames:|r Imported wizard '" .. name .. "' successfully!")
end
