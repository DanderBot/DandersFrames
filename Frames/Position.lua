local addonName, DF = ...

-- ============================================================
-- FRAMES POSITION MODULE
-- Contains mover, grid overlay, and position panel
-- ============================================================

function DF:CreateMoverFrame()
    -- Cannot create UI elements during combat
    if InCombatLockdown() then return end
    
    -- Don't recreate if already exists
    if DF.moverFrame then return end
    
    -- CRITICAL: Ensure container exists before creating mover
    if not DF.container then
        print("|cFFFF0000[DF Position]|r Cannot create mover - DF.container doesn't exist!")
        return
    end
    
    local mover = CreateFrame("Frame", "DandersFramesMover", DF.container, "BackdropTemplate")
    mover:SetAllPoints(DF.container)
    mover:SetFrameStrata("TOOLTIP")  -- Very high strata to be above secure frames
    mover:SetFrameLevel(100)
    mover:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    mover:SetBackdropColor(0.2, 0.6, 1.0, 0.3)
    mover:SetBackdropBorderColor(0.2, 0.6, 1.0, 0.8)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
    mover:Hide()
    
    local label = mover:CreateFontString(nil, "OVERLAY")
    label:SetPoint("CENTER")
    -- Set font explicitly to avoid "Font not set" errors
    label:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    label:SetText("Party Frames\nDrag to move")
    label:SetTextColor(1, 1, 1, 1)
    
    DF.moverFrame = mover
    
    mover:SetScript("OnDragStart", function(self)
        DF.isDragging = true
        DF.container:StartMoving()
        
        -- Start OnUpdate to sync test container position during drag
        self:SetScript("OnUpdate", function()
            local x, y = DF.container:GetCenter()
            if x and y then
                local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
                local offsetX, offsetY = x - screenWidth/2, y - screenHeight/2
                
                -- Sync testPartyContainer to container position (for live preview)
                if DF.testPartyContainer then
                    DF.testPartyContainer:ClearAllPoints()
                    DF.testPartyContainer:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
                end
            end
            
            -- Snap preview if enabled
            local db = DF:GetDB()
            if db.snapToGrid and DF.gridFrame and DF.gridFrame:IsShown() then
                DF:UpdateSnapPreview(DF.container)
            end
        end)
    end)
    
    mover:SetScript("OnDragStop", function(self)
        DF.container:StopMovingOrSizing()
        DF.isDragging = false
        
        -- Stop OnUpdate
        self:SetScript("OnUpdate", nil)
        
        -- Hide snap preview lines
        DF:HideSnapPreview()
        
        -- Get current position relative to screen center
        local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
        local centerX, centerY = DF.container:GetCenter()
        local x = centerX - screenWidth / 2
        local y = centerY - screenHeight / 2
        
        -- Snap to grid if enabled - re-read db to ensure current state
        local db = DF:GetDB()
        if db.snapToGrid and DF.gridFrame and DF.gridFrame:IsShown() then
            x, y = DF:SnapToGrid(x, y)
        end
        
        -- Apply snapped position
        DF.container:ClearAllPoints()
        DF.container:SetPoint("CENTER", UIParent, "CENTER", x, y)
        
        -- Sync testPartyContainer to final position
        if DF.testPartyContainer then
            DF.testPartyContainer:ClearAllPoints()
            DF.testPartyContainer:SetPoint("CENTER", UIParent, "CENTER", x, y)
        end
        
        -- Save position
        db.anchorPoint = "CENTER"
        db.anchorX = x
        db.anchorY = y
        
        -- Update position panel
        DF:UpdatePositionPanel()
    end)
    
    mover:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            DF:LockFrames()
        end
    end)
    
    DF.moverFrame = mover
    
    -- Create grid overlay
    DF:CreateGridOverlay()
    
    -- Create position control panel
    DF:CreatePositionPanel()
end

-- ============================================================
-- GRID OVERLAY
-- ============================================================

function DF:CreateGridOverlay()
    local grid = CreateFrame("Frame", "DandersFramesGrid", UIParent)
    grid:SetAllPoints(UIParent)
    grid:SetFrameStrata("BACKGROUND")
    grid:Hide()
    
    grid.lines = {}
    
    -- Create snap preview lines (shown during drag)
    local snapPreviewV = grid:CreateTexture(nil, "OVERLAY")
    snapPreviewV:SetColorTexture(1, 0.2, 0.2, 0.8)  -- Red color
    snapPreviewV:SetSize(3, GetScreenHeight())
    snapPreviewV:Hide()
    grid.snapPreviewV = snapPreviewV
    
    local snapPreviewH = grid:CreateTexture(nil, "OVERLAY")
    snapPreviewH:SetColorTexture(1, 0.2, 0.2, 0.8)  -- Red color
    snapPreviewH:SetSize(GetScreenWidth(), 3)
    snapPreviewH:Hide()
    grid.snapPreviewH = snapPreviewH
    
    local function CreateGridLines()
        -- Clear existing lines
        for _, line in ipairs(grid.lines) do
            line:Hide()
        end
        grid.lines = {}
        
        -- Get db based on current position panel mode
        local db
        if DF.positionPanelMode == "raid" then
            db = DF:GetRaidDB()
        else
            db = DF:GetDB()
        end
        local gridSize = db.gridSize or 20
        local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
        local centerX, centerY = screenWidth / 2, screenHeight / 2
        
        -- Vertical lines (from center outward)
        local x = 0
        while x <= screenWidth / 2 do
            -- Right of center
            local lineR = grid:CreateTexture(nil, "BACKGROUND")
            lineR:SetColorTexture(1, 1, 1, x == 0 and 0.5 or 0.15)
            lineR:SetSize(x == 0 and 2 or 1, screenHeight)
            lineR:SetPoint("CENTER", grid, "CENTER", x, 0)
            table.insert(grid.lines, lineR)
            
            -- Left of center (skip 0 - already drawn)
            if x > 0 then
                local lineL = grid:CreateTexture(nil, "BACKGROUND")
                lineL:SetColorTexture(1, 1, 1, 0.15)
                lineL:SetSize(1, screenHeight)
                lineL:SetPoint("CENTER", grid, "CENTER", -x, 0)
                table.insert(grid.lines, lineL)
            end
            
            x = x + gridSize
        end
        
        -- Horizontal lines (from center outward)
        local y = 0
        while y <= screenHeight / 2 do
            -- Above center
            local lineT = grid:CreateTexture(nil, "BACKGROUND")
            lineT:SetColorTexture(1, 1, 1, y == 0 and 0.5 or 0.15)
            lineT:SetSize(screenWidth, y == 0 and 2 or 1)
            lineT:SetPoint("CENTER", grid, "CENTER", 0, y)
            table.insert(grid.lines, lineT)
            
            -- Below center (skip 0 - already drawn)
            if y > 0 then
                local lineB = grid:CreateTexture(nil, "BACKGROUND")
                lineB:SetColorTexture(1, 1, 1, 0.15)
                lineB:SetSize(screenWidth, 1)
                lineB:SetPoint("CENTER", grid, "CENTER", 0, -y)
                table.insert(grid.lines, lineB)
            end
            
            y = y + gridSize
        end
    end
    
    grid:SetScript("OnShow", CreateGridLines)
    grid.RefreshLines = CreateGridLines
    
    DF.gridFrame = grid
end

-- Calculate snap position and return the grid line positions for preview
function DF:CalculateSnapPreview(x, y, container)
    local db
    if DF.positionPanelMode == "raid" then
        db = DF:GetRaidDB()
    else
        db = DF:GetDB()
    end
    local gridSize = db.gridSize or 20
    local snapThreshold = gridSize / 2
    
    -- Get frame dimensions
    local frameWidth = container:GetWidth()
    local frameHeight = container:GetHeight()
    
    -- Calculate edges
    local leftEdge = x - frameWidth / 2
    local rightEdge = x + frameWidth / 2
    local topEdge = y + frameHeight / 2
    local bottomEdge = y - frameHeight / 2
    
    -- Find snap X
    local snapLineX = nil
    local centerSnapX = math.floor((x / gridSize) + 0.5) * gridSize
    local leftSnapX = math.floor((leftEdge / gridSize) + 0.5) * gridSize
    local rightSnapX = math.floor((rightEdge / gridSize) + 0.5) * gridSize
    
    local centerDistX = math.abs(x - centerSnapX)
    local leftDistX = math.abs(leftEdge - leftSnapX)
    local rightDistX = math.abs(rightEdge - rightSnapX)
    
    if centerDistX <= leftDistX and centerDistX <= rightDistX and centerDistX <= snapThreshold then
        snapLineX = centerSnapX
    elseif leftDistX <= rightDistX and leftDistX <= snapThreshold then
        snapLineX = leftSnapX
    elseif rightDistX <= snapThreshold then
        snapLineX = rightSnapX
    end
    
    -- Find snap Y
    local snapLineY = nil
    local centerSnapY = math.floor((y / gridSize) + 0.5) * gridSize
    local topSnapY = math.floor((topEdge / gridSize) + 0.5) * gridSize
    local bottomSnapY = math.floor((bottomEdge / gridSize) + 0.5) * gridSize
    
    local centerDistY = math.abs(y - centerSnapY)
    local topDistY = math.abs(topEdge - topSnapY)
    local bottomDistY = math.abs(bottomEdge - bottomSnapY)
    
    if centerDistY <= topDistY and centerDistY <= bottomDistY and centerDistY <= snapThreshold then
        snapLineY = centerSnapY
    elseif bottomDistY <= topDistY and bottomDistY <= snapThreshold then
        snapLineY = bottomSnapY
    elseif topDistY <= snapThreshold then
        snapLineY = topSnapY
    end
    
    return snapLineX, snapLineY
end

-- Update snap preview lines position
function DF:UpdateSnapPreview(container)
    if not DF.gridFrame or not DF.gridFrame:IsShown() then return end
    
    local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
    local centerX, centerY = container:GetCenter()
    local x = centerX - screenWidth / 2
    local y = centerY - screenHeight / 2
    
    local snapLineX, snapLineY = DF:CalculateSnapPreview(x, y, container)
    
    -- Update vertical preview line
    if snapLineX then
        DF.gridFrame.snapPreviewV:ClearAllPoints()
        DF.gridFrame.snapPreviewV:SetPoint("CENTER", DF.gridFrame, "CENTER", snapLineX, 0)
        DF.gridFrame.snapPreviewV:Show()
    else
        DF.gridFrame.snapPreviewV:Hide()
    end
    
    -- Update horizontal preview line
    if snapLineY then
        DF.gridFrame.snapPreviewH:ClearAllPoints()
        DF.gridFrame.snapPreviewH:SetPoint("CENTER", DF.gridFrame, "CENTER", 0, snapLineY)
        DF.gridFrame.snapPreviewH:Show()
    else
        DF.gridFrame.snapPreviewH:Hide()
    end
end

-- Hide snap preview lines
function DF:HideSnapPreview()
    if DF.gridFrame then
        if DF.gridFrame.snapPreviewV then DF.gridFrame.snapPreviewV:Hide() end
        if DF.gridFrame.snapPreviewH then DF.gridFrame.snapPreviewH:Hide() end
    end
end

function DF:SnapToGrid(x, y)
    -- Get db based on current position panel mode
    local db, container
    if DF.positionPanelMode == "raid" then
        db = DF:GetRaidDB()
        container = DF.raidContainer
    else
        db = DF:GetDB()
        container = DF.container
    end
    local gridSize = db.gridSize or 20
    local snapThreshold = gridSize / 2
    
    -- Get frame dimensions for edge/center snapping
    local frameWidth = container:GetWidth()
    local frameHeight = container:GetHeight()
    
    -- Calculate edges and center positions relative to frame center
    local leftEdge = x - frameWidth / 2
    local rightEdge = x + frameWidth / 2
    local topEdge = y + frameHeight / 2
    local bottomEdge = y - frameHeight / 2
    
    -- Snap X (check center, left edge, right edge)
    local snappedX = x
    local centerSnapX = math.floor((x / gridSize) + 0.5) * gridSize
    local leftSnapX = math.floor((leftEdge / gridSize) + 0.5) * gridSize
    local rightSnapX = math.floor((rightEdge / gridSize) + 0.5) * gridSize
    
    -- Find closest snap point for X
    local centerDistX = math.abs(x - centerSnapX)
    local leftDistX = math.abs(leftEdge - leftSnapX)
    local rightDistX = math.abs(rightEdge - rightSnapX)
    
    if centerDistX <= leftDistX and centerDistX <= rightDistX and centerDistX <= snapThreshold then
        snappedX = centerSnapX
    elseif leftDistX <= rightDistX and leftDistX <= snapThreshold then
        snappedX = leftSnapX + frameWidth / 2
    elseif rightDistX <= snapThreshold then
        snappedX = rightSnapX - frameWidth / 2
    end
    
    -- Snap Y (check center, top edge, bottom edge)
    local snappedY = y
    local centerSnapY = math.floor((y / gridSize) + 0.5) * gridSize
    local topSnapY = math.floor((topEdge / gridSize) + 0.5) * gridSize
    local bottomSnapY = math.floor((bottomEdge / gridSize) + 0.5) * gridSize
    
    -- Find closest snap point for Y
    local centerDistY = math.abs(y - centerSnapY)
    local topDistY = math.abs(topEdge - topSnapY)
    local bottomDistY = math.abs(bottomEdge - bottomSnapY)
    
    if centerDistY <= topDistY and centerDistY <= bottomDistY and centerDistY <= snapThreshold then
        snappedY = centerSnapY
    elseif bottomDistY <= topDistY and bottomDistY <= snapThreshold then
        snappedY = bottomSnapY + frameHeight / 2
    elseif topDistY <= snapThreshold then
        snappedY = topSnapY - frameHeight / 2
    end
    
    return snappedX, snappedY
end

-- ============================================================
-- POSITION CONTROL PANEL (shared for party and raid)
-- ============================================================

function DF:CreatePositionPanel()
    -- Same color constants as main GUI
    local C_BACKGROUND = {r = 0.08, g = 0.08, b = 0.08, a = 0.95}
    local C_ELEMENT    = {r = 0.18, g = 0.18, b = 0.18, a = 1}
    local C_BORDER     = {r = 0.25, g = 0.25, b = 0.25, a = 1}
    local C_ACCENT     = {r = 0.45, g = 0.45, b = 0.95, a = 1}  -- Purple-Blue (matches main GUI)
    local C_RAID       = {r = 1.0, g = 0.5, b = 0.2, a = 1}
    local C_HOVER      = {r = 0.22, g = 0.22, b = 0.22, a = 1}
    local C_TEXT       = {r = 0.9, g = 0.9, b = 0.9, a = 1}
    
    -- Use positionPanelMode to determine which mode we're in
    local function GetAccentColor()
        if DF.positionPanelMode == "raid" then return C_RAID else return C_ACCENT end
    end
    
    -- Helper to get the correct DB based on mode
    local function GetPositionDB()
        if DF.positionPanelMode == "raid" then
            return DF:GetRaidDB()
        else
            return DF:GetDB()
        end
    end
    
    -- Helper to lock the correct frames based on mode
    local function LockCurrentFrames()
        if DF.positionPanelMode == "raid" then
            DF:LockRaidFrames()
        else
            DF:LockFrames()
        end
    end
    
    local function CreateElementBackdrop(frame)
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        frame:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, C_ELEMENT.a)
        frame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    end
    
    -- Main panel - matches main GUI style
    local panel = CreateFrame("Frame", "DandersFramesPositionPanel", UIParent, "BackdropTemplate")
    panel:SetSize(300, 268)
    panel:SetPoint("TOP", UIParent, "TOP", 0, -50)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetFrameLevel(100)  -- High level to ensure it's on top
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, C_BACKGROUND.a)
    panel:SetBackdropBorderColor(0, 0, 0, 1)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    
    -- Apply scale from settings when shown
    panel:SetScript("OnShow", function(self)
        local guiScale = DF.db and DF.db.party and DF.db.party.guiScale or 1.0
        self:SetScale(guiScale)
    end)
    
    -- Store for theme updates
    panel.themedElements = {}
    
    local function UpdateTheme()
        local c = GetAccentColor()
        for _, elem in ipairs(panel.themedElements) do
            if elem.UpdateThemeColor then
                elem:UpdateThemeColor(c)
            end
        end
        -- Update title text based on mode
        if panel.title then
            if DF.positionPanelMode == "raid" then
                panel.title:SetText("Raid Position")
            else
                panel.title:SetText("Position")
            end
        end
    end
    panel.UpdateTheme = UpdateTheme
    
    -- Title (matches main GUI title style)
    local c = GetAccentColor()
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 15, -12)
    title:SetText("Position")
    title:SetTextColor(c.r, c.g, c.b)
    title.UpdateThemeColor = function(self, col) self:SetTextColor(col.r, col.g, col.b) end
    table.insert(panel.themedElements, title)
    panel.title = title
    
    -- Close button (simple X like main GUI)
    local closeBtn = CreateFrame("Button", nil, panel)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetNormalFontObject("GameFontNormal")
    closeBtn:SetText("x")
    closeBtn:GetFontString():SetTextColor(0.6, 0.6, 0.6)
    closeBtn:SetScript("OnClick", function() LockCurrentFrames() end)
    closeBtn:SetScript("OnEnter", function(self) self:GetFontString():SetTextColor(1, 1, 1) end)
    closeBtn:SetScript("OnLeave", function(self) self:GetFontString():SetTextColor(0.6, 0.6, 0.6) end)
    
    -- X Position row
    local xLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    xLabel:SetPoint("TOPLEFT", 15, -40)
    xLabel:SetText("X Position")
    xLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    local xInput = CreateFrame("EditBox", nil, panel, "BackdropTemplate")
    xInput:SetSize(65, 22)
    xInput:SetPoint("TOPLEFT", 15, -56)
    CreateElementBackdrop(xInput)
    xInput:SetFontObject("GameFontHighlightSmall")
    xInput:SetJustifyH("CENTER")
    xInput:SetAutoFocus(false)
    xInput:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            local db = GetPositionDB()
            if DF.positionPanelMode == "raid" then
                db.raidAnchorX = val
                -- If editing profile, save as override
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                    DF.AutoProfilesUI:SetProfileSetting("raidAnchorX", val)
                    if DF.GUI and DF.GUI.UpdatePositionOverrideIndicator then
                        DF.GUI.UpdatePositionOverrideIndicator()
                    end
                end
                DF:UpdateRaidContainerPosition()
            else
                db.anchorX = val
                DF:UpdateContainerPosition()
            end
            -- Update override indicator in position panel
            if DF.positionPanel and DF.positionPanel.UpdatePositionOverride then
                DF.positionPanel.UpdatePositionOverride()
            end
        end
        self:ClearFocus()
    end)
    xInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.xInput = xInput
    
    -- X Nudge buttons
    local xMinus = CreateFrame("Button", nil, panel, "BackdropTemplate")
    xMinus:SetSize(22, 22)
    xMinus:SetPoint("LEFT", xInput, "RIGHT", 4, 0)
    CreateElementBackdrop(xMinus)
    local xMinusTxt = xMinus:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    xMinusTxt:SetPoint("CENTER")
    xMinusTxt:SetText("<")
    xMinus:SetScript("OnClick", function() DF:NudgePosition(-1, 0) end)
    xMinus:SetScript("OnEnter", function(self) self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1) end)
    xMinus:SetScript("OnLeave", function(self) self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1) end)
    
    local xPlus = CreateFrame("Button", nil, panel, "BackdropTemplate")
    xPlus:SetSize(22, 22)
    xPlus:SetPoint("LEFT", xMinus, "RIGHT", 2, 0)
    CreateElementBackdrop(xPlus)
    local xPlusTxt = xPlus:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    xPlusTxt:SetPoint("CENTER")
    xPlusTxt:SetText(">")
    xPlus:SetScript("OnClick", function() DF:NudgePosition(1, 0) end)
    xPlus:SetScript("OnEnter", function(self) self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1) end)
    xPlus:SetScript("OnLeave", function(self) self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1) end)
    
    -- Y Position row
    local yLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    yLabel:SetPoint("TOPLEFT", 160, -40)
    yLabel:SetText("Y Position")
    yLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    local yInput = CreateFrame("EditBox", nil, panel, "BackdropTemplate")
    yInput:SetSize(65, 22)
    yInput:SetPoint("TOPLEFT", 160, -56)
    CreateElementBackdrop(yInput)
    yInput:SetFontObject("GameFontHighlightSmall")
    yInput:SetJustifyH("CENTER")
    yInput:SetAutoFocus(false)
    yInput:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            local db = GetPositionDB()
            if DF.positionPanelMode == "raid" then
                db.raidAnchorY = val
                -- If editing profile, save as override
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                    DF.AutoProfilesUI:SetProfileSetting("raidAnchorY", val)
                    if DF.GUI and DF.GUI.UpdatePositionOverrideIndicator then
                        DF.GUI.UpdatePositionOverrideIndicator()
                    end
                end
                DF:UpdateRaidContainerPosition()
            else
                db.anchorY = val
                DF:UpdateContainerPosition()
            end
            -- Update override indicator in position panel
            if DF.positionPanel and DF.positionPanel.UpdatePositionOverride then
                DF.positionPanel.UpdatePositionOverride()
            end
        end
        self:ClearFocus()
    end)
    yInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.yInput = yInput
    
    -- Y Nudge buttons
    local yMinus = CreateFrame("Button", nil, panel, "BackdropTemplate")
    yMinus:SetSize(22, 22)
    yMinus:SetPoint("LEFT", yInput, "RIGHT", 4, 0)
    CreateElementBackdrop(yMinus)
    local yMinusTxt = yMinus:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    yMinusTxt:SetPoint("CENTER")
    yMinusTxt:SetText("v")
    yMinus:SetScript("OnClick", function() DF:NudgePosition(0, -1) end)
    yMinus:SetScript("OnEnter", function(self) self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1) end)
    yMinus:SetScript("OnLeave", function(self) self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1) end)
    
    local yPlus = CreateFrame("Button", nil, panel, "BackdropTemplate")
    yPlus:SetSize(22, 22)
    yPlus:SetPoint("LEFT", yMinus, "RIGHT", 2, 0)
    CreateElementBackdrop(yPlus)
    local yPlusTxt = yPlus:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    yPlusTxt:SetPoint("CENTER")
    yPlusTxt:SetText("^")
    yPlus:SetScript("OnClick", function() DF:NudgePosition(0, 1) end)
    yPlus:SetScript("OnEnter", function(self) self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1) end)
    yPlus:SetScript("OnLeave", function(self) self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1) end)
    
    -- Position Override Row (visible when editing auto profile)
    local posOverrideRow = CreateFrame("Frame", nil, panel)
    posOverrideRow:SetSize(270, 20)
    posOverrideRow:SetPoint("TOPLEFT", 15, -82)
    posOverrideRow:Hide()
    panel.posOverrideRow = posOverrideRow
    
    local posOverrideStar = posOverrideRow:CreateTexture(nil, "OVERLAY")
    posOverrideStar:SetSize(12, 12)
    posOverrideStar:SetPoint("LEFT", 0, 0)
    posOverrideStar:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
    posOverrideStar:SetVertexColor(1, 0.8, 0.2)
    
    local posOverrideText = posOverrideRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    posOverrideText:SetPoint("LEFT", posOverrideStar, "RIGHT", 4, 0)
    posOverrideText:SetText("Position Overridden")
    posOverrideText:SetTextColor(1, 0.8, 0.2)
    
    local posResetBtn = CreateFrame("Button", nil, posOverrideRow, "BackdropTemplate")
    posResetBtn:SetSize(70, 18)
    posResetBtn:SetPoint("LEFT", posOverrideText, "RIGHT", 8, 0)
    posResetBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    posResetBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    posResetBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    
    local posResetIcon = posResetBtn:CreateTexture(nil, "OVERLAY")
    posResetIcon:SetSize(10, 10)
    posResetIcon:SetPoint("LEFT", 4, 0)
    posResetIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
    posResetIcon:SetVertexColor(0.6, 0.6, 0.6)
    
    local posResetText = posResetBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    posResetText:SetPoint("LEFT", posResetIcon, "RIGHT", 2, 0)
    posResetText:SetText("Reset")
    posResetText:SetTextColor(0.7, 0.7, 0.7)
    
    posResetBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1, 0.8, 0.2, 1)
        posResetIcon:SetVertexColor(1, 0.8, 0.2)
        posResetText:SetTextColor(1, 0.8, 0.2)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reset Position to Global")
        GameTooltip:Show()
    end)
    posResetBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        posResetIcon:SetVertexColor(0.6, 0.6, 0.6)
        posResetText:SetTextColor(0.7, 0.7, 0.7)
        GameTooltip:Hide()
    end)
    posResetBtn:SetScript("OnClick", function()
        if DF.AutoProfilesUI then
            -- Reset position overrides
            DF.AutoProfilesUI:ResetProfileSetting("raidAnchorX")
            DF.AutoProfilesUI:ResetProfileSetting("raidAnchorY")
            
            -- Get global values and apply them
            local globalX = DF.AutoProfilesUI:GetGlobalValue("raidAnchorX") or 0
            local globalY = DF.AutoProfilesUI:GetGlobalValue("raidAnchorY") or 0
            
            local db = GetPositionDB()
            db.raidAnchorX = globalX
            db.raidAnchorY = globalY
            
            -- Update container position
            DF:UpdateRaidContainerPosition()
            
            -- Update position panel inputs
            DF:UpdatePositionPanel()
            
            -- Update position override indicator in main GUI
            if DF.GUI and DF.GUI.UpdatePositionOverrideIndicator then
                DF.GUI.UpdatePositionOverrideIndicator()
            end
        end
    end)
    
    -- Function to update position override visibility
    panel.UpdatePositionOverride = function()
        -- Debug mode shows indicator
        if DF.GUI and DF.GUI.IsOverrideDebugMode and DF.GUI.IsOverrideDebugMode() then
            posOverrideStar:Show()
            posOverrideText:SetText("Position (debug)")
            posResetBtn:Show()
            posOverrideRow:Show()
            return
        end
        
        if DF.positionPanelMode ~= "raid" then
            posOverrideRow:Hide()
            return
        end
        
        local AutoProfilesUI = DF.AutoProfilesUI
        if not AutoProfilesUI or not AutoProfilesUI:IsEditing() then
            posOverrideRow:Hide()
            return
        end
        
        -- Check if position is overridden
        local xOverridden = AutoProfilesUI:IsSettingOverridden("raidAnchorX")
        local yOverridden = AutoProfilesUI:IsSettingOverridden("raidAnchorY")
        
        if xOverridden or yOverridden then
            posOverrideText:SetText("Position Overridden")
            posOverrideRow:Show()
        else
            posOverrideRow:Hide()
        end
    end
    
    -- Snap to Grid checkbox
    local snapContainer = CreateFrame("Frame", nil, panel)
    snapContainer:SetSize(150, 24)
    snapContainer:SetPoint("TOPLEFT", 15, -108)
    
    local snapCheck = CreateFrame("CheckButton", nil, snapContainer, "BackdropTemplate")
    snapCheck:SetSize(18, 18)
    snapCheck:SetPoint("LEFT", 0, 0)
    CreateElementBackdrop(snapCheck)
    
    local snapCheckMark = snapCheck:CreateTexture(nil, "OVERLAY")
    snapCheckMark:SetTexture("Interface\\Buttons\\WHITE8x8")
    snapCheckMark:SetVertexColor(c.r, c.g, c.b)
    snapCheckMark:SetPoint("CENTER")
    snapCheckMark:SetSize(10, 10)
    snapCheck:SetCheckedTexture(snapCheckMark)
    snapCheck.checkMark = snapCheckMark
    snapCheck.UpdateThemeColor = function(self, col) self.checkMark:SetVertexColor(col.r, col.g, col.b) end
    table.insert(panel.themedElements, snapCheck)
    
    local snapLabel = snapContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    snapLabel:SetPoint("LEFT", snapCheck, "RIGHT", 8, 0)
    snapLabel:SetText("Snap to Grid")
    snapLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    snapCheck:SetScript("OnClick", function(self)
        local db = GetPositionDB()
        db.snapToGrid = self:GetChecked()
        if db.snapToGrid then
            if DF.gridFrame.RefreshLines then
                DF.gridFrame:Show()
                DF.gridFrame.RefreshLines()
            else
                DF.gridFrame:Show()
            end
        else
            DF.gridFrame:Hide()
            -- Hide snap preview lines when disabling
            DF:HideSnapPreview()
        end
    end)
    panel.snapCheck = snapCheck
    
    -- Grid Size slider (matches main GUI slider style)
    local gridLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    gridLabel:SetPoint("TOPLEFT", 15, -138)
    gridLabel:SetText("Grid Size")
    gridLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Track background
    local track = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    track:SetPoint("TOPLEFT", 15, -156)
    track:SetSize(200, 8)
    CreateElementBackdrop(track)
    
    -- Fill (colored portion)
    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", 1, 0)
    fill:SetHeight(6)
    fill:SetColorTexture(c.r, c.g, c.b, 0.8)
    
    -- Slider
    local slider = CreateFrame("Slider", nil, panel)
    slider:SetPoint("TOPLEFT", 15, -156)
    slider:SetSize(200, 8)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(10, 100)
    slider:SetValueStep(5)
    slider:SetObeyStepOnDrag(true)
    slider:SetHitRectInsets(-4, -4, -8, -8)
    
    -- Thumb
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 16)
    thumb:SetColorTexture(c.r, c.g, c.b, 1)
    slider:SetThumbTexture(thumb)
    
    -- Theme update for slider
    local sliderTheme = {
        UpdateThemeColor = function(self, col)
            fill:SetColorTexture(col.r, col.g, col.b, 0.8)
            thumb:SetColorTexture(col.r, col.g, col.b, 1)
        end
    }
    table.insert(panel.themedElements, sliderTheme)
    
    -- Grid value input
    local gridInput = CreateFrame("EditBox", nil, panel, "BackdropTemplate")
    gridInput:SetPoint("LEFT", track, "RIGHT", 10, 0)
    gridInput:SetSize(50, 20)
    CreateElementBackdrop(gridInput)
    gridInput:SetFontObject("GameFontHighlightSmall")
    gridInput:SetJustifyH("CENTER")
    gridInput:SetAutoFocus(false)
    
    local function UpdateFill()
        local val = slider:GetValue()
        local pct = (val - 10) / 90
        fill:SetWidth(math.max(1, pct * 198))
    end
    
    slider:SetScript("OnValueChanged", function(self, val)
        gridInput:SetText(tostring(math.floor(val)))
        UpdateFill()
        local db = GetPositionDB()
        db.gridSize = math.floor(val)
        -- Refresh grid lines with new size
        if DF.gridFrame and DF.gridFrame:IsShown() and DF.gridFrame.RefreshLines then
            DF.gridFrame.RefreshLines()
        end
    end)
    
    gridInput:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val and val >= 10 and val <= 100 then
            slider:SetValue(val)
        end
        self:ClearFocus()
    end)
    gridInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    
    panel.gridSlider = slider
    panel.gridInput = gridInput
    
    -- Reset Position button
    local resetBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    resetBtn:SetSize(85, 26)
    resetBtn:SetPoint("BOTTOMLEFT", 15, 15)
    CreateElementBackdrop(resetBtn)
    local resetIcon = resetBtn:CreateTexture(nil, "OVERLAY")
    resetIcon:SetPoint("LEFT", 6, 0)
    resetIcon:SetSize(16, 16)
    resetIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
    resetIcon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    local resetBtnText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    resetBtnText:SetPoint("LEFT", resetIcon, "RIGHT", 2, 0)
    resetBtnText:SetText("Reset")
    resetBtnText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    resetBtn:SetScript("OnClick", function() DF:ResetPosition() end)
    resetBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1) end)
    resetBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1) end)
    
    -- Center button
    local centerBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    centerBtn:SetSize(85, 26)
    centerBtn:SetPoint("BOTTOM", 0, 15)
    CreateElementBackdrop(centerBtn)
    local centerBtnText = centerBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    centerBtnText:SetPoint("CENTER")
    centerBtnText:SetText("Center")
    centerBtnText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    centerBtn:SetScript("OnClick", function() DF:CenterFrames() end)
    centerBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1) end)
    centerBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1) end)
    
    -- Lock button (matches main GUI button style)
    local lockBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    lockBtn:SetSize(85, 26)
    lockBtn:SetPoint("BOTTOMRIGHT", -15, 15)
    CreateElementBackdrop(lockBtn)
    local lockIcon = lockBtn:CreateTexture(nil, "OVERLAY")
    lockIcon:SetPoint("LEFT", 6, 0)
    lockIcon:SetSize(16, 16)
    lockIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\lock")
    lockIcon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    local lockBtnText = lockBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lockBtnText:SetPoint("LEFT", lockIcon, "RIGHT", 2, 0)
    lockBtnText:SetText("Lock")
    lockBtnText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    lockBtn:SetScript("OnClick", function() LockCurrentFrames() end)
    lockBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1) end)
    lockBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1) end)
    
    -- Apply initial theme
    UpdateTheme()
    
    DF.positionPanel = panel
end

function DF:UpdatePositionPanel()
    if not DF.positionPanel then return end
    
    local db
    local anchorX, anchorY
    
    if DF.positionPanelMode == "raid" then
        db = DF:GetRaidDB()
        anchorX = db.raidAnchorX or 0
        anchorY = db.raidAnchorY or 0
    else
        db = DF:GetDB()
        anchorX = db.anchorX or 0
        anchorY = db.anchorY or 0
    end
    
    DF.positionPanel.xInput:SetText(string.format("%.0f", anchorX))
    DF.positionPanel.yInput:SetText(string.format("%.0f", anchorY))
    DF.positionPanel.snapCheck:SetChecked(db.snapToGrid)
    DF.positionPanel.gridSlider:SetValue(db.gridSize or 20)
    DF.positionPanel.gridInput:SetText(tostring(db.gridSize or 20))
    
    -- Update position override indicator if editing profile
    if DF.positionPanel.UpdatePositionOverride then
        DF.positionPanel.UpdatePositionOverride()
    end
end

function DF:ResetPosition()
    if DF.positionPanelMode == "raid" then
        if DF.savedRaidPositionX and DF.savedRaidPositionY then
            local db = DF:GetRaidDB()
            db.raidAnchorX = DF.savedRaidPositionX
            db.raidAnchorY = DF.savedRaidPositionY
            DF:UpdateRaidContainerPosition()
            DF:UpdatePositionPanel()
            print("|cff00ff00DandersFrames:|r Raid position reset.")
        else
            print("|cffff0000DandersFrames:|r No saved position to reset to.")
        end
    else
        if DF.savedPositionX and DF.savedPositionY then
            local db = DF:GetDB()
            db.anchorX = DF.savedPositionX
            db.anchorY = DF.savedPositionY
            DF:UpdateContainerPosition()
            DF:UpdatePositionPanel()
            print("|cff00ff00DandersFrames:|r Position reset.")
        else
            print("|cffff0000DandersFrames:|r No saved position to reset to.")
        end
    end
end

function DF:NudgePosition(dx, dy)
    if DF.positionPanelMode == "raid" then
        local db = DF:GetRaidDB()
        db.raidAnchorX = (db.raidAnchorX or 0) + dx
        db.raidAnchorY = (db.raidAnchorY or 0) + dy
        -- If editing profile, save as override
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
            DF.AutoProfilesUI:SetProfileSetting("raidAnchorX", db.raidAnchorX)
            DF.AutoProfilesUI:SetProfileSetting("raidAnchorY", db.raidAnchorY)
            if DF.GUI and DF.GUI.UpdatePositionOverrideIndicator then
                DF.GUI.UpdatePositionOverrideIndicator()
            end
        end
        DF:UpdateRaidContainerPosition()
    else
        local db = DF:GetDB()
        db.anchorX = (db.anchorX or 0) + dx
        db.anchorY = (db.anchorY or 0) + dy
        DF:UpdateContainerPosition()
    end
    DF:UpdatePositionPanel()
end

function DF:CenterFrames()
    if DF.positionPanelMode == "raid" then
        local db = DF:GetRaidDB()
        db.raidAnchorX = 0
        db.raidAnchorY = 0
        -- If editing profile, save as override
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
            DF.AutoProfilesUI:SetProfileSetting("raidAnchorX", 0)
            DF.AutoProfilesUI:SetProfileSetting("raidAnchorY", 0)
            if DF.GUI and DF.GUI.UpdatePositionOverrideIndicator then
                DF.GUI.UpdatePositionOverrideIndicator()
            end
        end
        DF:UpdateRaidContainerPosition()
        DF:UpdatePositionPanel()
        print("|cff00ff00DandersFrames:|r Raid frames centered.")
    else
        local db = DF:GetDB()
        local horizontal = db.growDirection == "HORIZONTAL"
        local growthAnchor = db.growthAnchor or "START"
        local spacing = db.frameSpacing or 4
        
        -- Calculate full 5-frame size
        local frameCount = 5
        local totalWidth = frameCount * (db.frameWidth + spacing) - spacing
        local totalHeight = frameCount * (db.frameHeight + spacing) - spacing
        
        -- Calculate offset needed to visually center the frames
        -- The container anchor point is at CENTER of UIParent
        -- We need to offset the container so the visual center of frames is at screen center
        local offsetX, offsetY = 0, 0
        
        if horizontal then
            -- For horizontal layout, adjust X based on growth anchor
            if growthAnchor == "START" then
                -- Anchor is at left edge, frames grow right
                -- Visual center is at anchor + totalWidth/2
                -- To center: anchor needs to be at -totalWidth/2
                offsetX = -totalWidth / 2
            elseif growthAnchor == "CENTER" then
                -- Anchor is already at center of frames
                offsetX = 0
            elseif growthAnchor == "END" then
                -- Anchor is at right edge, frames grow left
                -- Visual center is at anchor - totalWidth/2
                -- To center: anchor needs to be at +totalWidth/2
                offsetX = totalWidth / 2
            end
            offsetY = 0
        else
            -- For vertical layout, adjust Y based on growth anchor
            if growthAnchor == "START" then
                -- Anchor is at top edge, frames grow down
                -- Visual center is at anchor - totalHeight/2
                -- To center: anchor needs to be at +totalHeight/2
                offsetY = totalHeight / 2
            elseif growthAnchor == "CENTER" then
                -- Anchor is already at center of frames
                offsetY = 0
            elseif growthAnchor == "END" then
                -- Anchor is at bottom edge, frames grow up
                -- Visual center is at anchor + totalHeight/2
                -- To center: anchor needs to be at -totalHeight/2
                offsetY = -totalHeight / 2
            end
            offsetX = 0
        end
        
        db.anchorX = offsetX
        db.anchorY = offsetY
        DF:UpdateContainerPosition()
        DF:UpdatePositionPanel()
        DF:UpdateAllFrames()
        
        print("|cff00ff00DandersFrames:|r Frames centered on screen.")
    end
end

function DF:UpdateContainerPosition()
    local db = DF:GetDB()
    local x, y = db.anchorX or 0, db.anchorY or 0
    
    DF.container:ClearAllPoints()
    DF.container:SetPoint("CENTER", UIParent, "CENTER", x, y)
    
    -- Also update mover if visible
    if DF.moverFrame and DF.moverFrame:IsShown() then
        DF.moverFrame:ClearAllPoints()
        DF.moverFrame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    end
    
    -- Also update test container if visible
    if DF.testPartyContainer then
        DF.testPartyContainer:ClearAllPoints()
        DF.testPartyContainer:SetPoint("CENTER", UIParent, "CENTER", x, y)
    end
end

function DF:UpdateRaidContainerPosition()
    if not DF.raidContainer then return end
    
    local db = DF:GetRaidDB()
    local x, y = db.raidAnchorX or 0, db.raidAnchorY or 0
    
    DF.raidContainer:ClearAllPoints()
    DF.raidContainer:SetPoint("CENTER", UIParent, "CENTER", x, y)
    
    -- Also update mover if visible
    if DF.raidMoverFrame and DF.raidMoverFrame:IsShown() then
        DF.raidMoverFrame:ClearAllPoints()
        DF.raidMoverFrame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    end
    
    -- Also update test container if visible
    if DF.testRaidContainer then
        DF.testRaidContainer:ClearAllPoints()
        DF.testRaidContainer:SetPoint("CENTER", UIParent, "CENTER", x, y)
    end
end

function DF:UnlockFrames()
    if InCombatLockdown() then
        print("|cffff0000DandersFrames:|r Cannot unlock frames during combat.")
        return
    end
    
    local db = DF:GetDB()
    
    -- Ensure container exists
    if not DF.container then
        print("|cffff0000DandersFrames:|r Cannot unlock - container doesn't exist!")
        return
    end
    
    -- Ensure mover frame exists (create if needed)
    if not DF.moverFrame then
        DF:CreateMoverFrame()
    end
    
    -- Safety check - if mover still doesn't exist, abort
    if not DF.moverFrame then
        print("|cffff0000DandersFrames:|r Cannot unlock - failed to create mover frame!")
        return
    end
    
    -- Save current position before making changes (for reset button)
    DF.savedPositionX = db.anchorX or 0
    DF.savedPositionY = db.anchorY or 0
    
    db.locked = false
    DF.positionPanelMode = "party"  -- Set mode for position panel
    
    -- Always use CENTER anchor for positioning
    db.anchorPoint = "CENTER"
    DF.container:ClearAllPoints()
    DF.container:SetPoint("CENTER", UIParent, "CENTER", db.anchorX or 0, db.anchorY or 0)
    DF.container:Show()  -- Ensure container is visible
    
    -- Ensure container has a reasonable size (might be 0 if headers haven't laid out yet)
    local cWidth, cHeight = DF.container:GetWidth(), DF.container:GetHeight()
    if cWidth < 50 or cHeight < 50 then
        -- Use fallback size based on settings
        local frameWidth = db.frameWidth or 100
        local frameHeight = db.frameHeight or 50
        local spacing = db.frameSpacing or 2
        local horizontal = (db.growDirection == "HORIZONTAL")
        
        if horizontal then
            DF.container:SetSize(5 * (frameWidth + spacing) - spacing, frameHeight)
        else
            DF.container:SetSize(frameWidth, 5 * (frameHeight + spacing) - spacing)
        end
        
        if DF.debugHeaders then
            print("|cFF00FF00[DF Position]|r Container size was too small, set fallback size")
        end
    end
    
    DF.container:SetMovable(true)
    
    -- Ensure mover frame matches container before showing
    DF.moverFrame:ClearAllPoints()
    DF.moverFrame:SetAllPoints(DF.container)
    DF.moverFrame:SetFrameStrata("TOOLTIP")  -- Very high strata to be above secure frames
    DF.moverFrame:SetFrameLevel(100)
    DF.moverFrame:Show()
    DF.moverFrame:Raise()
    
    -- Sync testPartyContainer to current position and size
    if DF.testPartyContainer then
        DF.testPartyContainer:ClearAllPoints()
        DF.testPartyContainer:SetPoint("CENTER", UIParent, "CENTER", db.anchorX or 0, db.anchorY or 0)
        DF.testPartyContainer:SetSize(DF.container:GetSize())
    end
    
    -- Debug info
    if DF.debugHeaders then
        print("|cFF00FF00[DF Position]|r Unlock - container size:", DF.container:GetWidth(), "x", DF.container:GetHeight())
        print("|cFF00FF00[DF Position]|r Unlock - mover size:", DF.moverFrame:GetWidth(), "x", DF.moverFrame:GetHeight())
        print("|cFF00FF00[DF Position]|r Unlock - mover strata:", DF.moverFrame:GetFrameStrata())
    end
    
    -- Show personal targeted spells mover if enabled
    if db.personalTargetedSpellEnabled and DF.ShowPersonalTargetedSpellsMover then
        DF:ShowPersonalTargetedSpellsMover()
    end
    
    -- Always refresh grid state from db when unlocking
    if DF.gridFrame then
        if db.snapToGrid then
            -- Refresh grid lines to ensure they match current settings
            if DF.gridFrame.RefreshLines then
                DF.gridFrame:Show()
                DF.gridFrame.RefreshLines()
            else
                DF.gridFrame:Show()
            end
        else
            DF.gridFrame:Hide()
        end
    end
    
    -- Show position panel and update its values from db
    if DF.positionPanel then
        DF:UpdatePositionPanel()
        if DF.positionPanel.UpdateTheme then
            DF.positionPanel:UpdateTheme()
        end
        DF.positionPanel:Show()
    end
    
    -- Update Display tab button if it exists
    if DF.displayLockButton and DF.displayLockButton.Text then
        DF.displayLockButton.Text:SetText("Lock Frames")
    end
    
    -- Enable test mode so user can position with full group visible
    DF:ShowTestFrames(true)
    
    -- Sync GUI toolbar buttons
    if DF.GUI then
        if DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
        if DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
    end
    
    print("|cff00ff00DandersFrames:|r Frames unlocked. Drag to move, right-click to lock.")
end

function DF:LockFrames()
    local db = DF:GetDB()
    db.locked = true
    DF.positionPanelMode = nil  -- Clear mode
    
    DF.container:SetMovable(false)
    DF.moverFrame:Hide()
    
    -- Hide personal targeted spells mover
    if DF.HidePersonalTargetedSpellsMover then
        DF:HidePersonalTargetedSpellsMover()
    end
    
    -- Stop any OnUpdate for snap preview
    DF.moverFrame:SetScript("OnUpdate", nil)
    
    -- Hide snap preview lines
    DF:HideSnapPreview()
    
    -- Hide grid
    if DF.gridFrame then
        DF.gridFrame:Hide()
    end
    
    -- Hide position panel
    if DF.positionPanel then
        DF.positionPanel:Hide()
    end
    
    -- Update saved position for next unlock's reset button
    DF.savedPositionX = db.anchorX or 0
    DF.savedPositionY = db.anchorY or 0
    
    -- Update Display tab button if it exists
    if DF.displayLockButton and DF.displayLockButton.Text then
        DF.displayLockButton.Text:SetText("Unlock Frames")
    end
    
    -- Sync GUI toolbar buttons
    if DF.GUI then
        if DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
        if DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
    end
    
    -- Disable test mode
    DF:HideTestFrames(true)
    
    print("|cff00ff00DandersFrames:|r Frames locked.")
end

