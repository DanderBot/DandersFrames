-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames

-- Icon Library Preview
-- Use /df debug icons (or /dficons) to open the preview window.
--
-- ★ THE LIST IS GENERATED, NOT KEPT HERE. The client cannot list a folder, so
-- DF.ICON_MANIFEST (GUI/IconManifest.lua) is written from both icon folders by
-- Tools/generate-icon-manifest.py, and test_icon_manifest.py fails when it drifts.
-- A hand-kept list here went stale at 25 of 87.

-- Each manifest key's folder, as the client addresses it. The kit's icons sit in
-- whichever host's Libs\DandersUI copy loaded, which is what GUI.MEDIA names.
local function FoldersOf()
    return {
        { key = "df",  title = "DandersFrames", path = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" },
        { key = "kit", title = DF.L["Shared UI kit"], path = DF.GUI.MEDIA .. "Icons\\" },
    }
end

local previewFrame = nil

local function CreateIconPreview()
    if previewFrame then
        previewFrame:Show()
        return
    end
    
    -- Colors. Neutrals that already match the shared GUI palette point at it
    -- (zero visual change); C_BORDER/C_TEXT/C_ACCENT differ from GUI.Colors and
    -- stay private (this static preview doesn't theme-track).
    local C_BG = DF.GUI.Colors.background
    local C_BORDER = {r = 0.3, g = 0.3, b = 0.3}
    local C_ACCENT = {r = 0.6, g = 0.4, b = 0.8}
    local C_TEXT_DIM = DF.GUI.Colors.textDim
    
    -- Main frame
    local frame = CreateFrame("Frame", "DFIconPreview", UIParent, "BackdropTemplate")
    -- Ride the shared GUI pixel grid: this surface is parented to UIParent, so it
    frame:SetSize(520, 560)
    frame:SetPoint("CENTER")
    DF.GUI:CreateElementBackdrop(frame, {
        bgColor     = { C_BG.r, C_BG.g, C_BG.b, 0.95 },
        borderColor = { C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 1 },
    })
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    
    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText(DF.L["Material Icons Preview"])
    title:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
    
    -- Subtitle
    local subtitle = frame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    local manifest = DF.ICON_MANIFEST or {}
    local total = 0
    for _, list in pairs(manifest) do total = total + #list end
    subtitle:SetText(format(DF.L["%d icons, drawn from Google Material Symbols (Apache 2.0)"], total))
    subtitle:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Close button
    local closeBtn = DF.GUI:CreateCloseButton(frame, { size = 20, onClick = function() frame:Hide() end })
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    
    -- Color buttons for testing SetVertexColor
    local colorLabel = frame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    colorLabel:SetPoint("TOPLEFT", 16, -50)
    colorLabel:SetText(DF.L["Theme Color:"])
    colorLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local colors = {
        {name = DF.L["White"], r = 1, g = 1, b = 1},
        {name = DF.L["Purple"], r = 0.6, g = 0.4, b = 0.8},
        {name = DF.L["Blue"], r = 0.3, g = 0.5, b = 0.9},
        {name = DF.L["Orange"], r = 0.9, g = 0.5, b = 0.2},
        {name = DF.L["Red"], r = 0.9, g = 0.3, b = 0.3},
        {name = DF.L["Green"], r = 0.3, g = 0.8, b = 0.4},
        {name = DF.L["Yellow"], r = 1, g = 0.8, b = 0.2},
        {name = DF.L["Gray"], r = 0.5, g = 0.5, b = 0.5},
    }
    
    local currentColor = colors[1]
    local iconTextures = {}
    
    local function UpdateIconColors()
        for _, tex in ipairs(iconTextures) do
            tex:SetVertexColor(currentColor.r, currentColor.g, currentColor.b)
        end
    end
    
    local colorBtns = {}
    for i, col in ipairs(colors) do
        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        btn:SetSize(20, 20)
        btn:SetPoint("LEFT", colorLabel, "RIGHT", 8 + (i-1) * 24, 0)
        DF.GUI:CreateElementBackdrop(btn, {
            bgColor     = { col.r, col.g, col.b, 1 },
            borderColor = { 0.2, 0.2, 0.2, 1 },
        })
        btn:SetScript("OnClick", function()
            currentColor = col
            UpdateIconColors()
            -- Update button borders
            for j, b in ipairs(colorBtns) do
                if j == i then
                    b:SetBackdropBorderColor(1, 1, 1, 1)
                else
                    b:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
                end
            end
        end)
        btn:SetScript("OnEnter", function(self)
            DF.GUI:ShowTooltip(self, { title = col.name })
        end)
        btn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
        
        if i == 1 then
            btn:SetBackdropBorderColor(1, 1, 1, 1)
        end
        
        table.insert(colorBtns, btn)
    end
    
    -- Icon grid: one section per icon folder, in a scroll frame -- the set outgrew
    -- a fixed window long ago.
    local ICON_SIZE = 32
    local CELL_SIZE = 56
    local ICONS_PER_ROW = 8
    local ROW_H = CELL_SIZE + 16
    local HEADER_H = 24

    local scroll = CreateFrame("ScrollFrame", nil, frame, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -84)
    scroll:SetPoint("BOTTOMRIGHT", -30, 36)
    DF.GUI.StyleScrollBar(scroll)
    local grid = CreateFrame("Frame", nil, scroll)
    grid:SetSize(ICONS_PER_ROW * CELL_SIZE, 10)
    scroll:SetScrollChild(grid)

    local function BuildCell(path, iconName, x, y)
        local container = CreateFrame("Button", nil, grid, "BackdropTemplate")
        container:SetSize(CELL_SIZE - 4, CELL_SIZE + 12)
        container:SetPoint("TOPLEFT", x, y)
        DF.GUI:CreateElementBackdrop(container, {
            bgColor     = { 0.12, 0.12, 0.12, 1 },
            borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5 },
        })

        local icon = container:CreateTexture(nil, "ARTWORK")
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon:SetPoint("TOP", 0, -4)
        icon:SetTexture(path)
        icon:SetVertexColor(currentColor.r, currentColor.g, currentColor.b)
        table.insert(iconTextures, icon)

        local label = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        label:SetPoint("BOTTOM", 0, 4)
        label:SetText(iconName)
        label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        label:SetWidth(CELL_SIZE - 8)
        label:SetWordWrap(false)

        container:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 1)
            DF.GUI:ShowTooltip(self, {
                title = iconName,
                lines = {
                    { text = path, color = { r = 0.6, g = 0.6, b = 0.6 } },
                    " ",
                    { text = DF.L["Click to copy texture path"], hint = true },
                },
            })
        end)
        container:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
            DF.GUI:HideTooltip()
        end)
        container:SetScript("OnClick", function()
            DF:Say(DF.L["Copied: "] .. path)
        end)
    end

    local y = 0
    for _, folder in ipairs(FoldersOf()) do
        local names = manifest[folder.key] or {}
        if #names > 0 then
            local header = grid:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            header:SetPoint("TOPLEFT", 4, y)
            header:SetText(format("%s  |cff888888(%d)|r", folder.title, #names))
            header:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
            y = y - HEADER_H
            for i, iconName in ipairs(names) do
                local row = math.floor((i - 1) / ICONS_PER_ROW)
                local col = (i - 1) % ICONS_PER_ROW
                BuildCell(folder.path .. iconName .. ".png", iconName, col * CELL_SIZE, y - row * ROW_H)
            end
            y = y - math.ceil(#names / ICONS_PER_ROW) * ROW_H - 8
        end
    end
    grid:SetHeight(math.max(10, -y))

    -- Usage info at bottom
    local usage = frame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    usage:SetPoint("BOTTOM", 0, 12)
    usage:SetText(DF.L["Click icon to copy path • Icons are white and can be tinted with SetVertexColor()"])
    usage:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    previewFrame = frame
end

-- Slash command
DF:RegisterDebugSlash("DFICONS", "Icon library browser", true, "/dficons")
SlashCmdList["DFICONS"] = function()
    CreateIconPreview()
end

-- Print load message
C_Timer.After(1, function()
    -- Only print if debug mode or first time
    -- DF:Say("Icon library loaded. Use /dficons to preview.")
end)
