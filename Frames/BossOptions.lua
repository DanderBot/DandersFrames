local addonName, DF = ...

-- ============================================================
-- BOSS FRAMES — STANDALONE OPTIONS PANEL
-- Opened via /dfbf config. Lightweight UI using native frames
-- (not the main Options.lua system, which is 8k lines).
-- Saves directly into DF:GetBossDB() and calls DF:RefreshBossFrames.
-- ============================================================

local CreateFrame = CreateFrame
local pairs, ipairs = pairs, ipairs

local panel

local function apply()
    if DF.RefreshBossFrames then DF:RefreshBossFrames() end
end

-- ============================================================
-- Generic slider factory
-- ============================================================
local function makeSlider(parent, label, key, minV, maxV, step, y)
    local sl = CreateFrame("Slider", "DFBossOpt_"..key, parent, "OptionsSliderTemplate")
    sl:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    sl:SetWidth(280)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    sl:SetObeyStepOnDrag(true)
    _G[sl:GetName().."Low"]:SetText(tostring(minV))
    _G[sl:GetName().."High"]:SetText(tostring(maxV))
    _G[sl:GetName().."Text"]:SetText(label)

    local edit = CreateFrame("EditBox", nil, sl, "InputBoxTemplate")
    edit:SetSize(50, 18)
    edit:SetPoint("LEFT", sl, "RIGHT", 12, 0)
    edit:SetAutoFocus(false)
    edit:SetNumeric(false) -- allow decimals
    edit:SetFontObject("GameFontHighlightSmall")
    sl.edit = edit

    sl:SetScript("OnValueChanged", function(self, val)
        if step < 1 then val = math.floor(val * 100 + 0.5) / 100 else val = math.floor(val + 0.5) end
        local db = DF:GetBossDB()
        db[key] = val
        edit:SetText(tostring(val))
        apply()
    end)
    edit:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText())
        if v then sl:SetValue(v) end
        self:ClearFocus()
    end)
    return sl
end

-- ============================================================
-- Generic checkbox factory
-- ============================================================
local function makeCheckbox(parent, label, key, x, y)
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb.Text:SetText(label)
    cb:SetScript("OnClick", function(self)
        DF:GetBossDB()[key] = self:GetChecked() and true or false
        apply()
    end)
    return cb
end

-- ============================================================
-- Generic dropdown factory (using UIDropDownMenu)
-- ============================================================
local function makeDropdown(parent, label, key, options, x, y)
    local labelFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labelFS:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    labelFS:SetText(label)

    local dd = CreateFrame("Frame", "DFBossOpt_DD_"..key, parent, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", labelFS, "BOTTOMLEFT", -18, -4)
    UIDropDownMenu_SetWidth(dd, 140)

    local function setSelected(val, displayText)
        DF:GetBossDB()[key] = val
        UIDropDownMenu_SetText(dd, displayText or val)
        apply()
    end

    UIDropDownMenu_Initialize(dd, function(self, level)
        for _, opt in ipairs(options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.text
            info.value = opt.value
            info.func = function() setSelected(opt.value, opt.text) end
            info.checked = (DF:GetBossDB()[key] == opt.value)
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    dd.refresh = function()
        local cur = DF:GetBossDB()[key]
        for _, opt in ipairs(options) do
            if opt.value == cur then UIDropDownMenu_SetText(dd, opt.text); return end
        end
    end
    return dd
end

-- ============================================================
-- PANEL BUILD
-- ============================================================

local function buildPanel()
    panel = CreateFrame("Frame", "DFBossFramesOptions", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(400, 640)
    panel:SetPoint("CENTER")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetFrameStrata("HIGH")
    panel:Hide()

    panel.TitleText:SetText("DandersFrames — Boss Frames")

    local widgets = {}

    local y = -10

    -- Unlock mover button
    local moverBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    moverBtn:SetSize(180, 22)
    moverBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
    moverBtn:SetText("Unlock / Lock mover")
    moverBtn:SetScript("OnClick", function() DF:ToggleBossMover() end)

    local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testBtn:SetSize(180, 22)
    testBtn:SetPoint("LEFT", moverBtn, "RIGHT", 4, 0)
    testBtn:SetText("Toggle test (3 bosses)")
    testBtn:SetScript("OnClick", function()
        local any
        for i = 1, 5 do if DF.BossFrames[i] and DF.BossFrames[i]._testMode then any = true; break end end
        DF:SetBossTestMode(any and 0 or 3)
    end)

    y = y - 34

    widgets[#widgets+1] = makeCheckbox(panel, "Show cast bar",      "showCastBar",    20, y)   y = y - 28
    widgets[#widgets+1] = makeCheckbox(panel, "Cast bar detached",  "castBarDetached",20, y)   y = y - 28
    widgets[#widgets+1] = makeCheckbox(panel, "Show power bar",     "showPowerBar",   20, y)   y = y - 28
    widgets[#widgets+1] = makeCheckbox(panel, "Show name",          "showName",       20, y)   y = y - 28
    widgets[#widgets+1] = makeCheckbox(panel, "Show health text",   "showHealthText", 20, y)   y = y - 28
    widgets[#widgets+1] = makeCheckbox(panel, "Hide Blizzard",      "hideBlizzard",   20, y)   y = y - 34

    -- Sliders
    local s1 = makeSlider(panel, "Frame width",   "frameWidth",   100, 400, 1, y); y = y - 42; widgets[#widgets+1] = s1
    local s2 = makeSlider(panel, "Frame height",  "frameHeight",   20, 100, 1, y); y = y - 42; widgets[#widgets+1] = s2
    local s3 = makeSlider(panel, "Spacing",       "frameSpacing",   0,  40, 1, y); y = y - 42; widgets[#widgets+1] = s3
    local s4 = makeSlider(panel, "Scale",         "frameScale",  0.5, 2.0, 0.05, y); y = y - 42; widgets[#widgets+1] = s4
    local s5 = makeSlider(panel, "Portrait size", "portraitSize",  20,  80, 1, y); y = y - 42; widgets[#widgets+1] = s5
    local s6 = makeSlider(panel, "Cast bar height","castBarHeight", 8,  40, 1, y); y = y - 42; widgets[#widgets+1] = s6
    local s7 = makeSlider(panel, "Power bar height","powerBarHeight",2, 20, 1, y); y = y - 42; widgets[#widgets+1] = s7

    -- Dropdowns in a right column
    local ddY = -44
    local dd1 = makeDropdown(panel, "Portrait position", "portraitPosition", {
        { text = "Left", value = "LEFT" },
        { text = "Right", value = "RIGHT" },
        { text = "Hidden", value = "HIDDEN" },
    }, 210, ddY); ddY = ddY - 52; widgets[#widgets+1] = dd1

    local dd2 = makeDropdown(panel, "Grow direction", "growDirection", {
        { text = "Down", value = "DOWN" },
        { text = "Up",   value = "UP" },
    }, 210, ddY); ddY = ddY - 52; widgets[#widgets+1] = dd2

    local dd3 = makeDropdown(panel, "Anchor", "anchor", {
        { text = "Right",        value = "RIGHT" },
        { text = "Left",         value = "LEFT" },
        { text = "Top",          value = "TOP" },
        { text = "Bottom",       value = "BOTTOM" },
        { text = "Top right",    value = "TOPRIGHT" },
        { text = "Top left",     value = "TOPLEFT" },
        { text = "Bottom right", value = "BOTTOMRIGHT" },
        { text = "Bottom left",  value = "BOTTOMLEFT" },
        { text = "Center",       value = "CENTER" },
    }, 210, ddY); ddY = ddY - 52; widgets[#widgets+1] = dd3

    local dd4 = makeDropdown(panel, "Health text align", "healthTextAnchor", {
        { text = "Left",   value = "LEFT" },
        { text = "Center", value = "CENTER" },
        { text = "Right",  value = "RIGHT" },
    }, 210, ddY); ddY = ddY - 52; widgets[#widgets+1] = dd4

    local dd5 = makeDropdown(panel, "Name align", "nameAnchor", {
        { text = "Left",   value = "LEFT" },
        { text = "Center", value = "CENTER" },
        { text = "Right",  value = "RIGHT" },
    }, 210, ddY); ddY = ddY - 52; widgets[#widgets+1] = dd5

    local ddCastIcon = makeDropdown(panel, "Cast bar icon", "castBarIconPosition", {
        { text = "Left",  value = "LEFT" },
        { text = "Right", value = "RIGHT" },
    }, 210, ddY); ddY = ddY - 52; widgets[#widgets+1] = ddCastIcon

    local dd6 = makeDropdown(panel, "Health text format", "healthTextFormat", {
        { text = "Percent (50%)",         value = "PERCENT" },
        { text = "Current (50M)",          value = "CURRENT" },
        { text = "Current + % (50M 50%)", value = "CURRENT_PERCENT" },
        { text = "Current / Max",          value = "CURRENT_MAX" },
    }, 210, ddY); ddY = ddY - 52; widgets[#widgets+1] = dd6

    -- Anchor offset sliders at bottom
    local sX = makeSlider(panel, "Anchor X", "anchorX", -1000, 1000, 1, y); y = y - 42; widgets[#widgets+1] = sX
    local sY = makeSlider(panel, "Anchor Y", "anchorY", -1000, 1000, 1, y); y = y - 42; widgets[#widgets+1] = sY

    panel.refreshAll = function()
        local db = DF:GetBossDB()
        for _, w in ipairs(widgets) do
            if w.Text and w.SetChecked then           -- checkbox
                -- find key by iterating label text? simpler: rebuild? OK we stored via closures. Use the bound db-read each build
                -- For each checkbox, compare its OnClick binding by re-reading via widget label → skip; instead store key on widget
            end
            if w.refresh then w.refresh() end
            if w.SetValue and w.edit then
                -- slider: find key from widget name
                local n = w:GetName()
                if n and n:find("^DFBossOpt_") then
                    local key = n:sub(11)
                    local val = db[key]
                    if val then
                        w:SetValue(val)
                        w.edit:SetText(tostring(val))
                    end
                end
            end
        end
        -- Re-sync checkboxes by their saved value via sibling iteration
        for _, child in ipairs({panel:GetChildren()}) do
            if child.SetChecked and child.Text then
                local label = child.Text:GetText()
                local keyMap = {
                    ["Show cast bar"] = "showCastBar",
                    ["Cast bar detached"] = "castBarDetached",
                    ["Show power bar"] = "showPowerBar",
                    ["Show name"] = "showName",
                    ["Show health text"] = "showHealthText",
                    ["Hide Blizzard"] = "hideBlizzard",
                }
                local k = keyMap[label]
                if k then child:SetChecked(db[k] and true or false) end
            end
        end
    end
end

function DF:ToggleBossOptions()
    if not panel then buildPanel() end
    if panel:IsShown() then
        panel:Hide()
    else
        panel.refreshAll()
        panel:Show()
    end
end
