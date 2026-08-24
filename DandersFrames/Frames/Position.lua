local addonName, DF = ...
local L = DF.L
local format = string.format

-- Header tracing -> debug console HEADERS category (see Frames/Headers.lua).
local headerDebug = DF:MakeDebugPrinter("HEADERS")

-- ============================================================
-- FRAMES POSITION MODULE
-- Contains mover, grid overlay, and position panel
-- ============================================================

-- ============================================================
-- RAIDPOS DIAGNOSTIC HELPERS
-- Targeted instrumentation for the "raid frames jump on roster
-- change and stay stuck" bug. Output goes through DF:Debug under
-- the "RAIDPOS" category so users can copy/paste from the Debug
-- Console. Logging cost is one boolean check when disabled.
-- ============================================================

-- DandersMover is OPTIONAL: nil here means every routing check below falls through to the
-- legacy movers unchanged. Resolved once at load; the lib is an OptionalDep so it has
-- already registered with LibStub by now.
local Mover = LibStub and LibStub("DandersMover-1.0", true)

local function ShortCaller(level)
    -- Returns "filename:line" of the caller `level` frames up.
    -- level=2 -> direct caller of the function that calls ShortCaller.
    local info = debugstack(level or 2, 1, 0)
    if not info then return "?" end
    -- debugstack format: "...\Frames\Position.lua:1841: in function 'SetPositionRecord'\n"
    local file, line = info:match("([^\\/]+):(%d+):")
    if file then return file .. ":" .. line end
    return "?"
end

-- Log a write to db.raidAnchorX/Y. Call BEFORE the assignment so
-- we can capture the old value, then perform the assignment.
function DF:LogRaidAnchorWrite(reason, newX, newY)
    -- ☠ DebugActive, not `DF.Debug` -- that only asked whether the function
    -- exists, which it always does, so ShortCaller's debugstack() built a
    -- stack string on every raid-anchor write with logging off.
    if not DF:DebugActive("RAIDPOS") then return end
    local db = DF:GetRaidDB()
    local oldX, oldY = db and db.raidAnchorX or 0, db and db.raidAnchorY or 0
    DF:Debug("RAIDPOS", "raidAnchor WRITE [%s] @ %s : (%.1f,%.1f) -> (%.1f,%.1f)",
        tostring(reason), ShortCaller(3), oldX, oldY, newX or 0, newY or 0)
end

-- ============================================================
-- PERMANENT MOVER HANDLE
-- Small always-visible drag handle for repositioning without unlock
-- ============================================================

local InCombatLockdown = InCombatLockdown

-- Quick action dispatch table
-- Each entry's `label` reads L["..."] at file scope, before the languageOverride
-- overlay is applied at ADDON_LOADED — so build the table in a registered refresh
-- fn. (The fn closures' own L[...] reads run at click time and are unaffected.)
local PERM_MOVER_ACTIONS = {}

local function RefreshPermMoverActions()
    PERM_MOVER_ACTIONS = {
    NONE              = { label = L["None"],                       combatSafe = true },
    OPEN_SETTINGS     = { label = L["Open Settings"],              combatSafe = true,  fn = function() DF:ToggleGUI() end },
    UNLOCK_FRAMES     = { label = L["Unlock Frames"],              combatSafe = false, fn = function(mode)
        if mode == "raid" then DF:UnlockRaidFrames() else DF:UnlockFrames() end
    end },
    TOGGLE_TEST       = { label = L["Toggle Test Mode"],           combatSafe = false, fn = function()
        -- Test mode lives in the companion; a mover button is a deliberate
        -- action, so load it rather than silently do nothing.
        if DF.EnsureOptionsLoaded and not DF:EnsureOptionsLoaded() then return end
        if DF.ToggleTestMode then DF:ToggleTestMode() end
    end },
    SWITCH_PROFILE    = { label = L["Quick Switch Profile"],       combatSafe = false, fn = function(mode, handle) DF:ShowPermanentMoverProfilePopup(handle) end },
    SWITCH_CC_PROFILE = { label = L["Quick Switch CC Profile"],    combatSafe = false, fn = function(mode, handle) DF:ShowPermanentMoverCCProfilePopup(handle) end },
    CYCLE_PROFILE     = { label = L["Cycle Next Profile"],         combatSafe = false, fn = function() DF:CycleNextProfile() end },
    CYCLE_CC_PROFILE  = { label = L["Cycle Next CC Profile"],      combatSafe = false, fn = function() DF:CycleNextCCProfile() end },
    TOGGLE_SOLO       = { label = L["Toggle Solo Mode"],           combatSafe = false, fn = function()
        local db = DF:GetDB()
        db.soloMode = not db.soloMode
        DF:UpdateAllFrames()
        if DF.UpdateDefaultPlayerFrame then DF:UpdateDefaultPlayerFrame() end
        DF:Say(format(L["Solo mode %s"], db.soloMode and L["enabled"] or L["disabled"]))
    end },
    RELOAD_UI         = { label = L["Reload UI"],                  combatSafe = true,  fn = function() ReloadUI() end },
    READY_CHECK       = { label = L["Ready Check"],                combatSafe = true,  fn = function()
        -- 12.0.7 moves DoReadyCheck into C_PartyInfo and Blizzard migrated
        -- their own callers with NO compat shim for the old global — prefer
        -- the namespaced version, fall back to the global on 12.0.5.
        if C_PartyInfo and C_PartyInfo.DoReadyCheck then
            C_PartyInfo.DoReadyCheck()
        else
            DoReadyCheck()
        end
    end },
    PULL_TIMER        = { label = L["Pull Timer"],                 combatSafe = true,  fn = function()
        local db = DF:GetDB()
        C_PartyInfo.DoCountdown(db.permanentMoverPullTimerDuration or 10)
    end },
    }
    DF.PERM_MOVER_ACTIONS = PERM_MOVER_ACTIONS
end

RefreshPermMoverActions()
DF:RegisterLocaleRefresh(RefreshPermMoverActions)

-- Cycle through profiles
function DF:CycleNextProfile()
    local profiles = DF:GetProfiles()
    if not profiles or #profiles < 2 then return end
    local current = DF:GetCurrentProfile()
    for i, name in ipairs(profiles) do
        if name == current then
            DF:SetProfile(profiles[(i % #profiles) + 1])
            return
        end
    end
end

function DF:CycleNextCCProfile()
    local CC = DF.ClickCast
    if not CC then return end
    local profiles = CC:GetProfileList()
    if not profiles or #profiles < 2 then return end
    local current = CC:GetActiveProfileName()
    for i, name in ipairs(profiles) do
        if name == current then
            local nextName = profiles[(i % #profiles) + 1]
            CC:SetActiveProfile(nextName)
            CC:ApplyBindings()
            DF:Say(format(L["Click-cast profile: %s"], nextName))
            return
        end
    end
end

-- Shared popup menu for profile switching
function DF:CreatePermanentMoverPopup()
    if DF.permanentMoverPopup then return DF.permanentMoverPopup end

    -- Neutral tones reuse the shared GUI palette (same numeric values, zero
    -- visual change). The accent here is passed in per-anchor (party/raid) by
    -- the callers, so no accent constant lives in this popup.
    local GUIColors = DF.GUI.Colors
    local C_ELEM  = GUIColors.element
    local C_HOVER = GUIColors.hover
    local C_BORDER = GUIColors.border

    local popup = CreateFrame("Frame", "DandersFramesPermanentMoverPopup", UIParent, "BackdropTemplate")
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(200)
    DF.GUI:CreatePanelBackdrop(popup, { bgAlpha = 0.95, borderColor = { 0, 0, 0, 1 } })
    popup:EnableMouse(true)
    popup:Hide()

    popup.title = popup:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    popup.title:SetPoint("TOPLEFT", 10, -8)

    popup.buttons = {}

    -- Close when clicking outside
    popup.closer = CreateFrame("Button", nil, UIParent)
    popup.closer:SetAllPoints(UIParent)
    popup.closer:SetFrameStrata("FULLSCREEN")
    popup.closer:SetFrameLevel(199)
    popup.closer:Hide()
    popup.closer:SetScript("OnClick", function() popup:Hide() end)

    popup:SetScript("OnShow", function() popup.closer:Show() end)
    popup:SetScript("OnHide", function() popup.closer:Hide() end)

    -- Apply GUI scale
    popup:SetScript("OnShow", function(self)
        self:SetScale(DF:GetWindowState().scale or 1.0)
        self.closer:Show()
    end)

    function popup:Populate(titleText, items, currentItem, onSelect, accentR, accentG, accentB)
        self.title:SetText(titleText)
        self.title:SetTextColor(accentR or 0.45, accentG or 0.45, accentB or 0.95)

        -- Hide all existing buttons
        for _, btn in ipairs(self.buttons) do btn:Hide() end

        local btnHeight = 22
        local btnWidth = 180
        local yOff = -28

        for idx, name in ipairs(items) do
            local btn = self.buttons[idx]
            if not btn then
                btn = CreateFrame("Button", nil, self, "BackdropTemplate")
                btn:SetSize(btnWidth, btnHeight)
                -- Selected/unselected colours are pushed below on every refresh.
                DF.GUI:CreateElementBackdrop(btn)
                btn.text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                btn.text:SetPoint("LEFT", 8, 0)
                btn.check = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                btn.check:SetPoint("RIGHT", -8, 0)
                btn.check:SetText(">")
                self.buttons[idx] = btn
            end

            btn:SetPoint("TOPLEFT", 5, yOff)
            btn.text:SetText(name)
            btn:Show()

            local isCurrent = (name == currentItem)
            if isCurrent then
                btn:SetBackdropColor(accentR or 0.45, accentG or 0.45, accentB or 0.95, 0.3)
                btn:SetBackdropBorderColor(accentR or 0.45, accentG or 0.45, accentB or 0.95, 0.5)
                btn.text:SetTextColor(1, 1, 1)
                btn.check:SetTextColor(accentR or 0.45, accentG or 0.45, accentB or 0.95)
                btn.check:Show()
            else
                btn:SetBackdropColor(C_ELEM.r, C_ELEM.g, C_ELEM.b, C_ELEM.a)
                btn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.3)
                btn.text:SetTextColor(0.8, 0.8, 0.8)
                btn.check:Hide()
            end

            btn:SetScript("OnEnter", function(b)
                if not isCurrent then
                    b:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
                end
            end)
            btn:SetScript("OnLeave", function(b)
                if isCurrent then
                    b:SetBackdropColor(accentR or 0.45, accentG or 0.45, accentB or 0.95, 0.3)
                else
                    b:SetBackdropColor(C_ELEM.r, C_ELEM.g, C_ELEM.b, C_ELEM.a)
                end
            end)
            btn:SetScript("OnClick", function()
                onSelect(name)
                self:Hide()
            end)

            yOff = yOff - btnHeight - 2
        end

        self:SetSize(btnWidth + 10, -yOff + 5)
    end

    DF.permanentMoverPopup = popup
    return popup
end

function DF:ShowPermanentMoverProfilePopup(anchorFrame)
    local popup = DF:CreatePermanentMoverPopup()
    local profiles = DF:GetProfiles()
    if not profiles or #profiles == 0 then return end
    local current = DF:GetCurrentProfile()
    local isRaid = anchorFrame and anchorFrame.isRaid
    local acc = DF.GUI.Colors.accent
    local ar, ag, ab = acc.r, acc.g, acc.b
    if isRaid then ar, ag, ab = 1.0, 0.5, 0.2 end

    popup:Populate(L["Profiles"], profiles, current, function(name)
        DF:SetProfile(name)
    end, ar, ag, ab)

    popup:ClearAllPoints()
    popup:SetPoint("BOTTOMLEFT", anchorFrame, "TOPLEFT", 0, 4)
    popup:Show()
end

function DF:ShowPermanentMoverCCProfilePopup(anchorFrame)
    local CC = DF.ClickCast
    if not CC then return end
    local popup = DF:CreatePermanentMoverPopup()
    local profiles = CC:GetProfileList()
    if not profiles or #profiles == 0 then return end
    local current = CC:GetActiveProfileName()
    local isRaid = anchorFrame and anchorFrame.isRaid
    local acc = DF.GUI.Colors.accent
    local ar, ag, ab = acc.r, acc.g, acc.b
    if isRaid then ar, ag, ab = 1.0, 0.5, 0.2 end

    popup:Populate(L["Click-Cast Profiles"], profiles, current, function(name)
        CC:SetActiveProfile(name)
        CC:ApplyBindings()
        DF:Say(format(L["Click-cast profile: %s"], name))
    end, ar, ag, ab)

    popup:ClearAllPoints()
    popup:SetPoint("BOTTOMLEFT", anchorFrame, "TOPLEFT", 0, 4)
    popup:Show()
end

function DF:CreatePermanentMover(container, mode)
    if not container then return end

    local isRaid = (mode == "raid")
    local handleName = isRaid and "DandersFramesRaidPermanentMover" or "DandersFramesPartyPermanentMover"

    -- Don't recreate
    if isRaid and DF.permanentRaidMover then return end
    if not isRaid and DF.permanentPartyMover then return end

    local db = isRaid and DF:GetRaidDB() or DF:GetDB()

    local handle = CreateFrame("Button", handleName, UIParent, "BackdropTemplate")
    handle:SetSize(db.permanentMoverWidth or 20, db.permanentMoverHeight or 20)
    handle:SetFrameStrata("MEDIUM")
    handle:SetFrameLevel(100)
    -- Chrome only, NOT CreateMoverBackdrop: this handle's colour is a user setting
    -- (permanentMoverColor) with its own hover/in-combat lifecycle in
    -- ApplyHandleColors below, so it must not take the theme hue.
    DF.GUI:CreateElementBackdrop(handle, { edgeSize = 1 })

    -- Store colors on handle from DB
    local color = db.permanentMoverColor or {r = 0.45, g = 0.45, b = 0.95}
    handle.accentR, handle.accentG, handle.accentB = color.r, color.g, color.b
    handle.isRaid = isRaid
    handle.mode = mode

    local function GetHandleColors()
        if InCombatLockdown() then
            local cDb = isRaid and DF:GetRaidDB() or DF:GetDB()
            local cc = cDb.permanentMoverCombatColor or {r = 0.8, g = 0.15, b = 0.15}
            return cc.r, cc.g, cc.b
        end
        return handle.accentR, handle.accentG, handle.accentB
    end

    local function ApplyHandleColors(hover)
        local r, g, b = GetHandleColors()
        local inCombat = InCombatLockdown()
        -- Use stronger alpha in combat so the red is clearly visible
        local bgAlpha = (hover or inCombat) and 0.7 or 0.4
        local borderAlpha = (hover or inCombat) and 1.0 or 0.7
        handle:SetBackdropColor(r, g, b, bgAlpha)
        handle:SetBackdropBorderColor(r, g, b, borderAlpha)
        -- Update dot colors to match
        local dotR, dotG, dotB = 1, 1, 1
        if inCombat then dotR, dotG, dotB = 1, 0.6, 0.6 end
        if handle.dots then
            for _, dot in ipairs(handle.dots) do
                dot:SetColorTexture(dotR, dotG, dotB, 0.6)
            end
        end
    end

    ApplyHandleColors(false)
    handle.ApplyHandleColors = ApplyHandleColors

    -- Grip dots — tiled to fill handle
    handle.dots = {}
    DF:UpdatePermanentMoverDots(handle)

    handle:EnableMouse(true)
    handle:SetMovable(true)
    handle:RegisterForDrag("LeftButton")
    handle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    handle:Hide()

    -- Fade animations
    handle.fadeIn = handle:CreateAnimationGroup()
    local alphaIn = handle.fadeIn:CreateAnimation("Alpha")
    alphaIn:SetFromAlpha(0)
    alphaIn:SetToAlpha(1)
    alphaIn:SetDuration(0.2)
    handle.fadeIn:SetScript("OnPlay", function() handle:Show() end)
    handle.fadeIn:SetScript("OnFinished", function() handle:SetAlpha(1) end)

    handle.fadeOut = handle:CreateAnimationGroup()
    local alphaOut = handle.fadeOut:CreateAnimation("Alpha")
    alphaOut:SetFromAlpha(1)
    alphaOut:SetToAlpha(0)
    alphaOut:SetDuration(0.2)
    handle.fadeOut:SetScript("OnFinished", function() handle:SetAlpha(0) end)

    -- Hover handlers
    handle.isDragging = false

    handle:SetScript("OnEnter", function(self)
        local hoverDb = isRaid and DF:GetRaidDB() or DF:GetDB()
        if hoverDb.permanentMoverShowOnHover then
            self.fadeOut:Stop()
            self.fadeIn:Play()
        end
        ApplyHandleColors(true)
    end)
    handle:SetScript("OnLeave", function(self)
        if self.isDragging then return end  -- Stay visible while dragging
        local hoverDb = isRaid and DF:GetRaidDB() or DF:GetDB()
        if hoverDb.permanentMoverShowOnHover then
            self.fadeIn:Stop()
            self.fadeOut:Play()
        end
        ApplyHandleColors(false)
    end)

    -- Drag handlers with combat protection
    -- Manual cursor tracking instead of StartMoving() — WoW's StartMoving
    -- doesn't handle scaled frames correctly and causes a position jump
    handle:SetScript("OnDragStart", function(self)
        -- Lib present: one editing surface. Open a mover session instead of
        -- dragging raw -- SetPositionRecord PRESERVES a record's `anchor`, so a
        -- raw drag under a live anchor moves x/y and the next Mover:Apply yanks
        -- the container back. The raw drag below is the lib-ABSENT fallback only
        -- (spec Decision 2).
        if Mover then
            if isRaid then DF:UnlockRaidFrames() else DF:UnlockFrames() end
            return
        end
        if InCombatLockdown() then return end
        self.isDragging = true
        -- Keep fully visible during drag
        self.fadeOut:Stop()
        self.fadeIn:Stop()
        self:SetAlpha(1)

        -- Use saved db position as truth — avoids scale ambiguity
        local dragDb = isRaid and DF:GetRaidDB() or DF:GetDB()
        local pScale = UIParent:GetEffectiveScale()
        local startCursorX, startCursorY = GetCursorPosition()
        startCursorX = startCursorX / pScale
        startCursorY = startCursorY / pScale
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local anchorX = isRaid and (dragDb.raidAnchorX or 0) or (dragDb.anchorX or 0)
        local anchorY = isRaid and (dragDb.raidAnchorY or 0) or (dragDb.anchorY or 0)
        local frameCX = sw / 2 + anchorX
        local frameCY = sh / 2 + anchorY
        handle._cursorOffX = frameCX - startCursorX
        handle._cursorOffY = frameCY - startCursorY

        -- Sync container and test containers live during drag
        self:SetScript("OnUpdate", function()
            local cursorX, cursorY = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            cursorX = cursorX / ps
            cursorY = cursorY / ps

            local sww, shh = GetScreenWidth(), GetScreenHeight()
            local ox = (cursorX + handle._cursorOffX) - sww / 2
            local oy = (cursorY + handle._cursorOffY) - shh / 2

            local s = container:GetScale() or 1
            container:ClearAllPoints()
            container:SetPoint("CENTER", UIParent, "CENTER", ox / s, oy / s)

            if isRaid then
                if DF.testRaidContainer then
                    DF.testRaidContainer:ClearAllPoints()
                    DF.testRaidContainer:SetPoint("CENTER", UIParent, "CENTER", ox / s, oy / s)
                end
            else
                if DF.testPartyContainer then
                    DF.testPartyContainer:ClearAllPoints()
                    DF.testPartyContainer:SetPoint("CENTER", UIParent, "CENTER", ox / s, oy / s)
                end
            end
        end)
    end)

    handle:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:SetScript("OnUpdate", nil)

        -- Re-evaluate hover state after drag ends
        local hoverDb = isRaid and DF:GetRaidDB() or DF:GetDB()
        if hoverDb.permanentMoverShowOnHover and not self:IsMouseOver() then
            self.fadeOut:Play()
        end
        if not self:IsMouseOver() then
            ApplyHandleColors(false)
        end

        if InCombatLockdown() then return end

        -- Compute final position from cursor (same math as OnUpdate)
        -- to avoid GetCenter() ambiguity on scaled frames
        local ps = UIParent:GetEffectiveScale()
        local finalCursorX, finalCursorY = GetCursorPosition()
        finalCursorX = finalCursorX / ps
        finalCursorY = finalCursorY / ps
        local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
        local x = (finalCursorX + self._cursorOffX) - screenWidth / 2
        local y = (finalCursorY + self._cursorOffY) - screenHeight / 2

        if isRaid then
            -- The auto-layout routing (and the RAIDPOS log line) now lives in
            -- DF:SetPositionRecord, so this site keeps its exact behaviour -- an active
            -- layout still edits THAT layout's position rather than the base anchors --
            -- while the record and the scalar mirror are written together.
            DF:SetPositionRecord("raid", { point = "CENTER", x = x, y = y }, "DragMover:OnDragStop")
            DF:UpdateRaidContainerPosition()
        else
            DF:SetPositionRecord("party", { point = "CENTER", x = x, y = y })
            DF:UpdateContainerPosition()
        end
    end)

    -- Click handlers for quick actions
    handle:SetScript("OnMouseDown", function(self, button)
        self.clickButton = button
        self.isClick = true
    end)

    handle:SetScript("OnMouseUp", function(self, button)
        if self.isDragging then
            self.isClick = false
            return  -- OnDragStop handles the drag
        end
        if not self.isClick then return end
        self.isClick = false

        local actionDb = isRaid and DF:GetRaidDB() or DF:GetDB()
        local actionKey
        local isShift = IsShiftKeyDown()

        if button == "LeftButton" and isShift then
            actionKey = actionDb.permanentMoverActionShiftLeft
        elseif button == "LeftButton" then
            actionKey = actionDb.permanentMoverActionLeft
        elseif button == "RightButton" and isShift then
            actionKey = actionDb.permanentMoverActionShiftRight
        elseif button == "RightButton" then
            actionKey = actionDb.permanentMoverActionRight
        end

        local action = actionKey and DF.PERM_MOVER_ACTIONS[actionKey]
        if action and action.fn then
            if InCombatLockdown() and not action.combatSafe then
                DF:Say(L["Cannot use this action in combat."])
                return
            end
            action.fn(mode, self)
        end
    end)

    if isRaid then
        DF.permanentRaidMover = handle
    else
        DF.permanentPartyMover = handle
    end

    -- Create roster/login event frame for re-anchoring (once, shared)
    -- Combat state is handled by Core.lua's PLAYER_REGEN events
    if not DF.permanentMoverEventFrame then
        DF.permanentMoverEventFrame = CreateFrame("Frame")
        DF.permanentMoverEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        DF.permanentMoverEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        DF.permanentMoverEventFrame:SetScript("OnEvent", function(_, event)
            DF:Debug("POSITION", "Mover event: %s — scheduling anchor update in 0.2s", event)
            C_Timer.After(0.2, function()
                DF:UpdatePermanentMoverAnchor("party")
                DF:UpdatePermanentMoverAnchor("raid")
            end)
        end)
    end

    -- Apply anchor and visibility
    DF:UpdatePermanentMoverAnchor(mode)
    DF:UpdatePermanentMoverVisibility()
end

function DF:UpdatePermanentMoverDots(handle)
    if not handle then return end
    local w, h = handle:GetSize()

    -- Hide all existing dots first
    for _, dot in ipairs(handle.dots) do
        dot:Hide()
    end

    -- Calculate grid: 6px spacing between dots, 4px padding from edges
    local padding = 4
    local spacing = 6
    local cols = math.max(1, math.floor((w - padding * 2) / spacing) + 1)
    local rows = math.max(1, math.floor((h - padding * 2) / spacing) + 1)
    local totalNeeded = cols * rows

    -- Create more dot textures if needed
    while #handle.dots < totalNeeded do
        local dot = handle:CreateTexture(nil, "OVERLAY")
        dot:SetSize(2, 2)
        dot:SetColorTexture(1, 1, 1, 0.6)
        handle.dots[#handle.dots + 1] = dot
    end

    -- Position and show dots in a tiled grid, centered in the handle
    local gridW = (cols - 1) * spacing
    local gridH = (rows - 1) * spacing
    local startX = -gridW / 2
    local startY = -gridH / 2
    local idx = 0
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            idx = idx + 1
            local dot = handle.dots[idx]
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", handle, "CENTER", startX + col * spacing, startY + row * spacing)
            dot:Show()
        end
    end
end

function DF:UpdatePermanentMoverSize(mode)
    local isRaid = (mode == "raid")
    local handle = isRaid and DF.permanentRaidMover or DF.permanentPartyMover
    if not handle then return end

    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    handle:SetSize(db.permanentMoverWidth or 20, db.permanentMoverHeight or 20)
    DF:UpdatePermanentMoverDots(handle)
end

function DF:UpdatePermanentMoverColor(mode)
    local isRaid = (mode == "raid")
    local handle = isRaid and DF.permanentRaidMover or DF.permanentPartyMover
    if not handle then return end

    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local color = db.permanentMoverColor or {r = 0.45, g = 0.45, b = 0.95}
    handle.accentR, handle.accentG, handle.accentB = color.r, color.g, color.b
    handle.ApplyHandleColors(false)
end

function DF:GetPermanentMoverAttachFrame(mode)
    local isRaid = (mode == "raid")
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local attachTo = db.permanentMoverAttachTo or "CONTAINER"
    local inTestMode = isRaid and DF.raidTestMode or DF.testMode

    if attachTo == "CONTAINER" then
        if inTestMode then
            return isRaid and DF.testRaidContainer or DF.testPartyContainer
                or isRaid and DF.raidContainer or DF.container
        end
        return isRaid and DF.raidContainer or DF.container
    end

    -- Find first or last visible unit frame, respecting sort order
    local targetFrame
    if inTestMode then
        -- Use test mode frames
        local frames = isRaid and DF.testRaidFrames or DF.testPartyFrames
        if frames then
            for i = 1, #frames do
                local frame = frames[i]
                if frame and frame:IsShown() then
                    if attachTo == "FIRST" and not targetFrame then
                        targetFrame = frame
                    end
                    if attachTo == "LAST" then
                        targetFrame = frame
                    end
                end
            end
        end
    else
        -- Determine first/last by actual screen position
        -- This works regardless of sorting system, data order, or secure handler state
        local candidates = {}
        local iterateFunc = function(frame)
            if frame and frame:IsShown() and frame:GetLeft() then
                candidates[#candidates + 1] = frame
            end
        end

        if isRaid then
            DF:IterateRaidFrames(iterateFunc)
        else
            local playerFrame = DF:GetPlayerFrame()
            if playerFrame then iterateFunc(playerFrame) end
            for i = 1, 4 do
                local frame = DF:GetPartyFrame(i)
                if frame then iterateFunc(frame) end
            end
        end

        if #candidates > 0 then
            -- Sort by visual position: primary axis depends on grow direction
            -- Use top-left as origin: lowest top+left = first, highest = last
            -- For horizontal layouts: sort by left, then by top (descending)
            -- For vertical layouts: sort by top (descending = higher first), then by left
            local horizontal = (db.growDirection == "HORIZONTAL")
            table.sort(candidates, function(a, b)
                local aLeft, aTop = a:GetLeft(), a:GetTop()
                local bLeft, bTop = b:GetLeft(), b:GetTop()
                if horizontal then
                    if math.abs(aLeft - bLeft) > 1 then return aLeft < bLeft end
                    return aTop > bTop  -- higher = first
                else
                    if math.abs(aTop - bTop) > 1 then return aTop > bTop end
                    return aLeft < bLeft  -- further left = first
                end
            end)

            if attachTo == "FIRST" then
                targetFrame = candidates[1]
            else
                targetFrame = candidates[#candidates]
            end
        end
    end

    -- Fallback to container
    local fallback
    if inTestMode then
        fallback = isRaid and (DF.testRaidContainer or DF.raidContainer) or (DF.testPartyContainer or DF.container)
    else
        fallback = isRaid and DF.raidContainer or DF.container
    end
    return targetFrame or fallback
end

function DF:UpdatePermanentMoverAnchor(mode)
    local isRaid = (mode == "raid")
    local handle = isRaid and DF.permanentRaidMover or DF.permanentPartyMover
    if not handle then return end

    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local anchor = db.permanentMoverAnchor or "TOPLEFT"
    local offsetX = db.permanentMoverOffsetX or 0
    local offsetY = db.permanentMoverOffsetY or 0
    local attachFrame = DF:GetPermanentMoverAttachFrame(mode)

    DF:Debug("POSITION", "UpdatePermanentMoverAnchor(%s): anchor=%s offset=%.0f,%.0f attachFrame=%s",
        mode, anchor, offsetX, offsetY, attachFrame and attachFrame:GetName() or "nil")

    handle:ClearAllPoints()
    handle:SetPoint(anchor, attachFrame, anchor, offsetX, offsetY)
end

function DF:UpdatePermanentMoverCombatState()
    local handles = {}
    if DF.permanentPartyMover then handles[#handles + 1] = { handle = DF.permanentPartyMover, db = DF:GetDB() } end
    if DF.permanentRaidMover then handles[#handles + 1] = { handle = DF.permanentRaidMover, db = DF:GetRaidDB() } end

    local inCombat = InCombatLockdown()

    for _, info in ipairs(handles) do
        local h, db = info.handle, info.db
        if not db.permanentMover then
            -- Not enabled, skip
        elseif db.permanentMoverHideInCombat then
            if inCombat then
                h.fadeIn:Stop()
                h.fadeOut:Stop()
                h:Hide()
            else
                h:Show()
                if db.permanentMoverShowOnHover then
                    h:SetAlpha(0)
                else
                    h:SetAlpha(1)
                end
                h.ApplyHandleColors(false)
            end
        else
            -- Visible in combat — hide, update colors, re-show to force redraw
            local wasShown = h:IsShown()
            if wasShown then h:Hide() end

            if inCombat and db.permanentMoverShowOnHover then
                h.fadeOut:Stop()
                h.fadeIn:Stop()
            end

            if inCombat then
                local cc = db.permanentMoverCombatColor or {r = 0.8, g = 0.15, b = 0.15}
                h:SetBackdropColor(cc.r, cc.g, cc.b, 0.7)
                h:SetBackdropBorderColor(cc.r, cc.g, cc.b, 1.0)
                if h.dots then
                    for _, dot in ipairs(h.dots) do
                        dot:SetColorTexture(1, 0.6, 0.6, 0.6)
                    end
                end
            else
                local r, g, b = h.accentR or 0.45, h.accentG or 0.45, h.accentB or 0.95
                local isHover = h:IsMouseOver()
                h:SetBackdropColor(r, g, b, isHover and 0.7 or 0.4)
                h:SetBackdropBorderColor(r, g, b, isHover and 1.0 or 0.7)
                if h.dots then
                    for _, dot in ipairs(h.dots) do
                        dot:SetColorTexture(1, 1, 1, 0.6)
                    end
                end
            end

            if wasShown then
                h:Show()
                if inCombat or not db.permanentMoverShowOnHover then
                    h:SetAlpha(1)
                elseif not h:IsMouseOver() then
                    h:SetAlpha(0)
                end
            end
        end
    end
end

function DF:UpdatePermanentMoverVisibility()
    local inCombat = InCombatLockdown()
    DF:Debug("POSITION", "UpdatePermanentMoverVisibility: combat=%s", tostring(inCombat))

    -- Party
    if DF.permanentPartyMover then
        local db = DF:GetDB()
        -- Show if enabled and locked, but hide if raid test mode is active
        local show = db.permanentMover and db.locked and not DF.raidTestMode and not IsInRaid()
        DF:Debug("POSITION", "  Party mover: enabled=%s locked=%s show=%s",
            tostring(db.permanentMover), tostring(db.locked), tostring(show))
        if show then
            if inCombat and db.permanentMoverHideInCombat then
                DF.permanentPartyMover:Hide()
            else
                DF.permanentPartyMover:Show()
                if db.permanentMoverShowOnHover and not DF.permanentPartyMover:IsMouseOver() then
                    DF.permanentPartyMover:SetAlpha(0)
                else
                    DF.permanentPartyMover:SetAlpha(1)
                end
                DF.permanentPartyMover.ApplyHandleColors(false)
            end
            DF.container:SetMovable(true)
        else
            DF.permanentPartyMover:Hide()
            if db.locked and not db.permanentMover then
                DF.container:SetMovable(false)
            end
        end
    end

    -- Raid
    if DF.permanentRaidMover and DF.raidContainer then
        local db = DF:GetRaidDB()
        local raidEnabled = db.permanentMover
        DF:Debug("POSITION", "  Raid mover: enabled=%s locked=%s inRaid=%s testMode=%s",
            tostring(raidEnabled), tostring(db.raidLocked), tostring(IsInRaid()), tostring(DF.raidTestMode))
        -- In raid test mode, also show if party mover is enabled
        if DF.raidTestMode and not raidEnabled then
            raidEnabled = DF:GetDB().permanentMover
        end
        -- Only show if in raid test mode or actually in a raid group
        local inRaid = IsInRaid() or DF.raidTestMode
        local show = raidEnabled and db.raidLocked and inRaid
        -- Hide if party test mode is active
        if DF.testMode then show = false end
        if show then
            if inCombat and db.permanentMoverHideInCombat then
                DF.permanentRaidMover:Hide()
            else
                DF.permanentRaidMover:Show()
                if db.permanentMoverShowOnHover and not DF.permanentRaidMover:IsMouseOver() then
                    DF.permanentRaidMover:SetAlpha(0)
                else
                    DF.permanentRaidMover:SetAlpha(1)
                end
                DF.permanentRaidMover.ApplyHandleColors(false)
            end
            -- ☠ PROTECTED IN COMBAT -- and ONLY on the raid side. DF.raidContainer is
            -- built from SecureFrameTemplate (Init.lua / Headers.lua); DF.container is a
            -- plain Frame, which is why the party block above needs no guard and this one
            -- does. Both calls raised a blocked action any time this ran during combat.
            --
            -- ⚠ Guard the two CALLS, not the function. This function is deliberately
            -- combat-aware -- `inCombat and db.permanentMoverHideInCombat` above is the
            -- whole point of the hide-in-combat option -- so an early return would kill
            -- the feature it is being called to deliver. Movability is a no-op in combat
            -- anyway (the drag handler cannot reposition a secure frame mid-fight), and
            -- the next out-of-combat call restores the correct state.
            if not inCombat then
                DF.raidContainer:SetMovable(true)
            end
        else
            DF.permanentRaidMover:Hide()
            if db.raidLocked and not db.permanentMover and not inCombat then
                DF.raidContainer:SetMovable(false)
            end
        end
    end
end

-- Center the party or raid frames on screen. mode = "raid" | anything else = party.
-- Survives Phase C without an in-addon caller: the write is the same record funnel
-- everything else uses, and external/future callers keep it.
function DF:CenterFrames(mode)
    if mode == "raid" then
        DF:SetPositionRecord("raid", { point = "CENTER", x = 0, y = 0 }, "CenterFrames")
        -- If editing profile, save as override
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
            DF.AutoProfilesUI:SetProfileSetting("raidAnchorX", 0)
            DF.AutoProfilesUI:SetProfileSetting("raidAnchorY", 0)
            if DF.GUI and DF.GUI.UpdatePositionOverrideIndicator then
                DF.GUI.UpdatePositionOverrideIndicator()
            end
        end
        DF:UpdateRaidContainerPosition()
        DF:Say(L["Raid frames centered."])
    else
        -- The container is placed by its CENTER and sized to the full five-frame
        -- extent regardless of party size, so the offset that centres it is zero.
        DF:SetPositionRecord("party", { point = "CENTER", x = 0, y = 0 })
        DF:UpdateContainerPosition()
        DF:UpdateAllFrames()
        DF:Say(L["Frames centered on screen."])
    end
end

-- ============================================================
-- POSITION RECORDS
-- The one place that knows where a container is supposed to sit.
-- ============================================================
-- A record is { point, x, y, anchor } in UIParent units measured from UIParent CENTER --
-- the shape DandersMover reads through getPos and MUTATES IN PLACE. GetPositionRecord
-- therefore returns the LIVE db table, never a copy.
--
-- The legacy scalars (anchorX/anchorY, raidAnchorX/raidAnchorY) stay as a WRITE-THROUGH
-- MIRROR for this minor. Two reasons, both load-bearing:
--   * 30+ resident readers across Init.lua / Headers.lua / Core.lua / AutoProfiles.lua
--     still read the scalars, and rewriting all of them in one change is how a
--     positioning regression ships.
--   * The raid auto-layout overlay can only override TOP-LEVEL SCALAR keys.
--     ApplyRuntimeProfile deep-copies a whole-table override into a frozen overlay and
--     the overlay proxy's __newindex only fires for top-level writes, so `db.position.x =
--     v` would reach neither -- a table-valued override reads stale and loses writes.
-- DF:SetPositionRecord is the ONLY funnel that writes either shape, so they cannot drift.

-- key   = the db key holding the record; db = the table that DRIVES the display;
-- fold  = the scalars can move behind the record's back (a raid auto layout overrides
--         them, or a legacy reader still owns them), so a read folds the effective
--         scalar in when IT moved rather than the record (see lastNoted below);
-- route = while the RAID db drives the record, a write is offered to the active auto
--         layout first (the scalars are layout-overridable).
-- Phase B added "personal" (personalTargetedPosition, raid-layout routed) and
-- "targetedList" (targetedListPosition, party-only) on the Phase A pattern.
local RECORD_SPECS = {
    party = { key = "position", xKey = "anchorX", yKey = "anchorY", x = 0, y = -325,
              db = function() return DF:GetDB() end },
    raid  = { key = "position", xKey = "raidAnchorX", yKey = "raidAnchorY", x = -6.666610717773438, y = -25,
              db = function() return DF:GetRaidDB() end, fold = true, route = true },
    -- The personal block is per-mode and driven by the RAID db in a raid / raid test
    -- (TargetedSpells.lua GetPersonalDB), so the record is read from that same table.
    personal = { key = "personalTargetedPosition", xKey = "personalTargetedSpellX", yKey = "personalTargetedSpellY",
                 x = 0, y = -150, fold = true, route = true,
                 db = function() return DF.GetPersonalTargetedDB and DF:GetPersonalTargetedDB() or DF:GetDB() end },
    targetedList = { key = "targetedListPosition", xKey = "targetedListX", yKey = "targetedListY", x = 0, y = -10,
                     fold = true, db = function() return DF:GetDB("party") end },
}

local function recordSpec(mode)
    return RECORD_SPECS[mode] or RECORD_SPECS.party
end

-- ☠ WHAT THE RECORD HELD THE LAST TIME DF AND THE SCALAR AGREED, per record table (weak
-- keys: a profile switch or import swaps the table and the note goes with it).
--
-- The raid scalar can legitimately differ from the record for two opposite reasons and
-- the read path has to tell them apart:
--   (a) an auto layout overrides raidAnchorX/raidAnchorY (or one just deactivated) --
--       the SCALAR is the truth and must be folded into the record, or the layout
--       would not drive the container and the base would not come back afterwards;
--   (b) DandersMover mutated the record IN PLACE and has not called onChanged yet --
--       the RECORD is the truth. The lib's every write is `pos = getPos(); pos.x = v;
--       Notify()`, and Notify calls getPos AGAIN before onChanged, so folding the
--       scalar in here would erase the drag before DF ever saw it. The raid container
--       could not be moved by the lib at all.
-- (b) is exactly "the record no longer holds what we last noted", so that is the test.
local lastNoted = setmetatable({}, { __mode = "k" })

local function noteRecord(rec, x, y)
    local m = lastNoted[rec]
    if not m then
        m = {}
        lastNoted[rec] = m
    end
    m.x, m.y = x, y
end

-- True when nobody has mutated the record behind our back since it was last noted. An
-- un-noted record counts as unchanged: the lib always reads (and so notes) a record
-- before it touches it, so a pending mutation on a never-seen record cannot exist.
local function recordUnchanged(rec)
    local m = lastNoted[rec]
    return (not m) or (m.x == rec.x and m.y == rec.y)
end

-- The live record for a mode. Seeds it from the scalars when absent (belt for a profile
-- that dodged DF:MigrateContainerPositionRecords -- an import, or a downgrade/upgrade
-- round trip).
function DF:GetPositionRecord(mode)
    local spec = recordSpec(mode)
    local db = spec.db()
    -- Pre-init (DF.db nil) GetDB hands back the shared DEFAULTS table; hand out a
    -- throwaway instead so a stray write cannot rewrite the shipped defaults.
    if not db or db == DF.PartyDefaults or db == DF.RaidDefaults then
        return { point = "CENTER", x = spec.x, y = spec.y }
    end

    local rec = db[spec.key]
    if type(rec) ~= "table" then
        rec = {
            point = "CENTER",
            x = tonumber(db[spec.xKey]) or spec.x,
            y = tonumber(db[spec.yKey]) or spec.y,
        }
        db[spec.key] = rec
    end
    rec.point = rec.point or "CENTER"

    if spec.fold then
        -- ☠ FOLD THE EFFECTIVE SCALAR IN WHEN IT IS THE ONE THAT MOVED. An active auto
        -- layout overrides raidAnchorX/raidAnchorY (never `position` -- see the header
        -- note), and DF:GetRaidDB() returns the overlay view, so this is what makes a
        -- layout's position actually drive the container. The record's stored x/y
        -- therefore holds the layout's value for as long as that layout is active; it
        -- self-heals once the layout deactivates, because that read folds the base
        -- scalar back. The scalars are the authority while a layout is up -- deliberately.
        -- But only when the RECORD is still what we last noted: a record that moved
        -- behind our back is a DandersMover in-place mutation waiting for onChanged, and
        -- it must survive this read (see lastNoted above).
        local sx, sy = tonumber(db[spec.xKey]), tonumber(db[spec.yKey])
        if sx and sy then
            if (sx ~= rec.x or sy ~= rec.y) and recordUnchanged(rec) then
                rec.x, rec.y = sx, sy
            end
            if sx == rec.x and sy == rec.y then
                noteRecord(rec, sx, sy)
            end
        end
        rec.x = tonumber(rec.x) or spec.x
        rec.y = tonumber(rec.y) or spec.y
    else
        rec.x = tonumber(rec.x) or spec.x
        rec.y = tonumber(rec.y) or spec.y
    end
    return rec
end

-- The ONE funnel. Writes the record and its scalar mirror together.
-- `pos` may be the live record itself (DandersMover mutates in place and then calls
-- onChanged) or a fresh table from a legacy drag handler; both are handled.
-- `reason` is the DF:LogRaidAnchorWrite label -- pass the call site's name so the RAIDPOS
-- debug channel keeps reading the way it does today.
function DF:SetPositionRecord(mode, pos, reason)
    if type(pos) ~= "table" then return end
    local spec = recordSpec(mode)
    local db = spec.db()
    if not db or db == DF.PartyDefaults or db == DF.RaidDefaults then return end

    local x = tonumber(pos.x) or 0
    local y = tonumber(pos.y) or 0

    -- Routing applies while the RAID db drives the record: always for raid, and for
    -- personal only in a raid / raid test (its db() then IS the raid overlay).
    if spec.route and db == DF:GetRaidDB() then
        if spec == RECORD_SPECS.raid and DF.LogRaidAnchorWrite then
            DF:LogRaidAnchorWrite(reason or "SetPositionRecord", x, y)
        end
        -- ☠ THE ACTIVE LAYOUT GETS FIRST REFUSAL, exactly as DragMover:OnDragStop and
        -- DF:ResolvePositionTarget do. While a layout drives the frames it OWNS the
        -- position; writing the base anchors underneath it does not move anything and
        -- quietly corrupts the user's base position instead. Falls through when the
        -- routing declines (no active layout, or mid-edit where the preview path
        -- captures it). Keep all three call sites in step.
        local apu = DF.AutoProfilesUI
        local routed = false
        if apu then
            if spec == RECORD_SPECS.raid then
                -- Refreshes the raid container itself (unchanged Phase A behaviour).
                routed = apu.SetActiveLayoutRaidPosition and apu:SetActiveLayoutRaidPosition(x, y)
            else
                -- The caller applies afterwards (mode.apply / onChanged).
                routed = apu.SetActiveLayoutRaidPair and apu:SetActiveLayoutRaidPair(spec.xKey, spec.yKey, x, y)
            end
        end
        if routed then
            -- The layout took it (override + live overlay). Keep the record on the same
            -- value and note it, so the next read sees record and effective scalar agree
            -- rather than a phantom mutation. The base scalars are NOT written -- that is
            -- the whole point of routing.
            local live = db[spec.key]
            if type(live) == "table" then
                live.x, live.y = x, y
                noteRecord(live, x, y)
            end
            return
        end
    end

    local rec = db[spec.key]
    if type(rec) ~= "table" then
        rec = {}
        db[spec.key] = rec
    end

    if rec == pos then
        -- The lib mutated the live record in place; just normalise it.
        rec.point = rec.point or "CENTER"
        rec.x, rec.y = x, y
    else
        -- An incoming table with NO anchor is an x/y move, not a detach: keep whatever
        -- anchor the record already holds. Only the lib's in-place mutation (the
        -- `rec == pos` branch above, which is where its Detach lands) may clear one.
        local prev = rec.anchor
        rec.point = pos.point or "CENTER"
        rec.x, rec.y = x, y
        rec.anchor = nil
        if type(pos.anchor) == "table" then
            local a = pos.anchor
            rec.anchor = {
                target = a.target, mode = a.mode, edge = a.edge, align = a.align,
                point = a.point, relPoint = a.relPoint,
                offsetX = a.offsetX, offsetY = a.offsetY,
            }
        else
            rec.anchor = prev
        end
    end

    -- The mirror. Every legacy reader takes these.
    db[spec.xKey], db[spec.yKey] = x, y
    noteRecord(rec, x, y)
end

function DF:UpdateContainerPosition()
    local db = DF:GetDB()
    local rec = DF:GetPositionRecord("party")
    local point = rec.point or "CENTER"
    local x, y = rec.x or 0, rec.y or 0
    local scale = db.frameScale or 1.0

    -- Record coordinates are UIParent units, so the /scale division is what converts
    -- them into the container's own scaled space -- identical to the effective-scale
    -- ratio DandersMover's Lib.ApplyPosition uses. Unchanged from the scalar version.
    DF.container:SetScale(scale)
    DF.container:ClearAllPoints()
    DF.container:SetPoint(point, UIParent, "CENTER", x / scale, y / scale)

    -- Also update test container if visible
    if DF.testPartyContainer then
        DF.testPartyContainer:SetScale(scale)
        DF.testPartyContainer:ClearAllPoints()
        DF.testPartyContainer:SetPoint(point, UIParent, "CENTER", x / scale, y / scale)
    end
end

function DF:UpdateRaidContainerPosition()
    if not DF.raidContainer then return end
    if InCombatLockdown() then return end

    local db = DF:GetRaidDB()
    -- GetPositionRecord overlays the effective raidAnchorX/raidAnchorY, so an active
    -- auto layout still drives the container through this read.
    local rec = DF:GetPositionRecord("raid")
    local point = rec.point or "CENTER"
    local x, y = rec.x or 0, rec.y or 0
    local scale = db.frameScale or 1.0

    -- ☠ CENTER-anchor compensation, RETIRED 2026-08-18 -- this now always adds (0, 0).
    -- It shifted the container to hold CENTER content still as the roster grew, against
    -- #867. That was a workaround one layer below the real bug (the CENTER compounding,
    -- fixed at source in 50a3e7c5), and it was actively harmful: CENTER already grows
    -- symmetrically about the container centre, so the centroid never moved, and this
    -- pinned the leading edge instead -- measured in game as the container and mover
    -- dragged 316px left at Wrap 7 / Center Right / 8 groups (Krathe, 2026-08-18).
    -- The call stays so the reasoning has one home: see ComputeRaidContainerCompensation
    -- in Headers.lua before reinstating anything here.
    local dx, dy = 0, 0
    if DF.ComputeRaidContainerCompensation then
        dx, dy = DF:ComputeRaidContainerCompensation()
    end
    -- Anchor To: Main Group — a CONSTANT anchor-reference shift (settings only, never
    -- roster). NOT the retired compensation above: see ComputeRaidMainGroupAnchorOffset
    -- in Headers.lua for the distinction and the sign rules. Container, mover and test
    -- container all take it below, so the drag box always frames what it claims to.
    if DF.ComputeRaidMainGroupAnchorOffset then
        local ax, ay = DF:ComputeRaidMainGroupAnchorOffset()
        dx, dy = dx + ax, dy + ay
    end
    local cx, cy = x + dx, y + dy

    -- ☠ DebugActive, not `DF.Debug`: ShortCaller runs debugstack(), and this
    -- fires on every raid container reposition.
    if DF:DebugActive("RAIDPOS") then
        if dx ~= 0 or dy ~= 0 then
            DF:Debug("RAIDPOS", "UpdateRaidContainerPosition @ %s : applying (%.1f,%.1f) +comp(%.1f,%.1f) -> (%.1f,%.1f) scale=%.3f combat=%s",
                ShortCaller(3), x, y, dx, dy, cx, cy, scale, tostring(InCombatLockdown()))
        else
            DF:Debug("RAIDPOS", "UpdateRaidContainerPosition @ %s : applying (%.1f,%.1f) scale=%.3f combat=%s",
                ShortCaller(3), x, y, scale, tostring(InCombatLockdown()))
        end
    end

    DF.raidContainer:SetScale(scale)
    DF.raidContainer:ClearAllPoints()
    DF.raidContainer:SetPoint(point, UIParent, "CENTER", cx / scale, cy / scale)

    -- ☠ THE TEST CONTAINER TAKES THE COMPENSATION TOO — both read the one number
    -- ComputeRaidContainerCompensation returns (Aphoex, 2026-08-15). The comp rides
    -- ON THE CONTAINER, mirroring live — the test frame calculator no longer folds
    -- it into frame offsets. One accounting model in both modes; the calculator's
    -- testMode comp fork is retired.
    if DF.testRaidContainer then
        DF.testRaidContainer:SetScale(scale)
        DF.testRaidContainer:ClearAllPoints()
        DF.testRaidContainer:SetPoint(point, UIParent, "CENTER", cx / scale, cy / scale)
    end
end

function DF:UnlockFrames()
    if InCombatLockdown() then
        DF:Err(L["Cannot unlock frames during combat."])
        return
    end

    -- No DandersMover, no editing surface. The frames still APPLY their record;
    -- the one fallback for MOVING them is the permanent handle (spec Decision 1b).
    if not Mover then
        DF:Say(L["DandersMover is disabled. Re-enable it in the AddOns list, or turn on Enable Permanent Mover under Frame options for a basic drag handle."])
        return
    end

    -- Unlocking shows test frames, and test mode lives in the load-on-demand
    -- companion. This is a deliberate user action (/df unlock, mover button),
    -- so load the companion rather than let the shim no-op leave the movers up
    -- with no frames in them. Failure already reported by Ensure.
    if DF.EnsureOptionsLoaded and not DF:EnsureOptionsLoaded() then
        return
    end

    -- Only the party scope's keys get proxies (no raid proxy, dimmed or
    -- otherwise), and they are forced relevant so this works inside a raid.
    -- The user's per-element toggles prune that list; the container being one of the
    -- pruned ones is not a reason to refuse, an EMPTY list is.
    local filter = DF.MoverBridge and DF.MoverBridge:SessionFilter("party") or "DandersFrames"
    if type(filter) == "table" and #filter.keys == 0 then
        DF:Say(format(L["All %s movers are turned off under DandersFrames in /mover config."], L["Party Frames"]))
        return
    end
    if DF.MoverBridge then DF.MoverBridge:RequestScope("party") end
    Mover:Unlock(filter)
end

function DF:LockFrames()
    -- A DandersMover session owns the unlock: end it there and let the Locked callback
    -- restore db.locked + release the test claim. Returning is not optional -- on the lib
    -- path that callback is the only thing that restores db.locked.
    if Mover and Mover:IsUnlocked() then
        Mover:Lock()
        return
    end

    local db = DF:GetDB()
    db.locked = true

    -- Restore permanent mover visibility (keeps container movable if enabled)
    DF:UpdatePermanentMoverVisibility()

    -- Update Display tab button if it exists
    if DF.displayLockButton and DF.displayLockButton.Text then
        DF.displayLockButton.Text:SetText(L["Unlock Frames"])
    end

    -- Sync GUI toolbar buttons
    if DF.GUI then
        if DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
        if DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
    end

    DF:Say(L["Frames locked."])
end

-- ============================================================
-- BLIZZARD EDIT MODE — stand down while it is open
-- ============================================================
-- Entering /edit left DF half-dressed. The game closes DandersFramesGUI and
-- DandersFramesTestPanel for us -- both are in UISpecialFrames -- but the position
-- panel is NOT, so it stayed up, and behind it the grid, the movers and the test
-- preview all kept running: two grids overlapping and fake party frames sitting on
-- top of Blizzard's own editor. Field-reported.
--
-- The actual gap is that DF had no Edit Mode integration at all; the two windows
-- that did close were closing by accident of UISpecialFrames membership.
--
-- Locking is the right response and needs nothing new: LockFrames/LockRaidFrames
-- already hide the position panel, the grid, the movers and the pinned drag chrome,
-- and release unlock's test claim.
--
-- ⚠ NOT restored on exit, deliberately. Blizzard's Edit Mode does not put anyone
-- else's windows back either, and silently re-unlocking frames under someone who
-- has just finished rearranging their UI is worse than making them click Unlock.
local function standDownForEditMode()
    if InCombatLockdown() then return end   -- Edit Mode is unreachable in combat; belt anyway

    -- ☠ THE MOVER SESSION GOES FIRST. Its Locked callback restores db.locked /
    -- db.raidLocked, so by the time the two blocks below run they correctly see the
    -- frames as locked and skip LockFrames/LockRaidFrames -- which is what we want,
    -- because those two would otherwise tear down a legacy overlay that was never built.
    if Mover and Mover:IsUnlocked() then
        Mover:Lock()
    end

    local partyDb = DF.GetDB and DF:GetDB()
    if partyDb and not partyDb.locked then
        partyDb.locked = true
        if DF.LockFrames then DF:LockFrames() end
    end

    local raidDb = DF.GetRaidDB and DF:GetRaidDB()
    if raidDb and not raidDb.raidLocked then
        raidDb.raidLocked = true
        if DF.LockRaidFrames then DF:LockRaidFrames() end
    end

    -- Drop the user's claim too, so no preview survives into Edit Mode. This also
    -- settles the aura containers: turning test mode off hands the real data
    -- provider back, which is what keeps Edit Mode's sample auras out of our rows
    -- (see Frames/AuraContainer.lua -- test mode owns the provider switch while it
    -- is running, so the usual guard stands aside for it).
    if DF.SetTestModeOwner then
        DF:SetTestModeOwner("party", "user", false, true)
        DF:SetTestModeOwner("raid", "user", false, true)
    end
end

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("EditMode.Enter", standDownForEditMode, DF)
end


-- ============================================================
-- POSITION TARGETS — the resolver behind the public API
-- ============================================================
-- Core/API.lua's DandersFrames_GetPositionTargets / GetPosition / SetPosition are thin
-- shells over this. The logic lives HERE because this is the file that owns what "a
-- position" means; API.lua stays what it already is, a documented wall of global
-- wrappers.
--
-- Written for MSUF's Edit Mode (Mapko, 2026-08-06), which wants to drag DF's frames from
-- its own editor without touching DandersFramesDB_v2.
--
-- ☠ THE ID SPACE IS PUBLIC THE MOMENT AN ADDON SHIPS AGAINST IT. "party", "raid",
-- "pinned1".."pinnedN". Renaming one silently breaks an integration that has no way to
-- detect the change — ADD ids, never rename or repurpose them.
--
-- ⚠ Scoped deliberately to what was asked for: party, raid, and pinned sets. Personal
-- Targeted and the Targeted List also have records and can be added later without
-- breaking anyone (adding an id is safe; removing one is not). They are out of v1
-- because each needs its own enabled-state question answered, and a public API is a bad
-- place to guess.
--
-- ⚠ ONE RECORD SHAPE behind the API now: every target keeps a DandersMover record
-- {point, x, y, anchor} (party/raid: db.position; pinned: set.position). A pinned set
-- may be glued to the frames container (a point-mode `anchor` onto DandersFrames:party
-- /raid, mirrored in the deprecated `anchorTo`), in which case x/y are a fine offset from
-- that corner rather than a screen position. GetPosition reports both so a caller can
-- tell the difference instead of assuming screen coordinates. Ids are frozen: pinnedN
-- resolves against the CURRENT mode; personal / targetedList are not public.

local API_PINNED_PREFIX = "pinned"

-- Resolve an id to everything the public wrappers need, or nil if the id is unknown /
-- the subsystem is not loaded. Never creates anything: an id for a pinned set that does
-- not exist resolves to nil rather than conjuring one.
function DF:ResolvePositionTarget(id)
    if type(id) ~= "string" then return nil end

    if id == "party" or id == "raid" then
        local db = (id == "raid") and DF:GetRaidDB() or DF:GetDB()
        if not db then return nil end
        local rec = DF:GetPositionRecord(id)
        return {
            id      = id,
            kind    = id,
            label   = (id == "raid") and "Raid Frames" or "Party Frames",
            enabled = true,   -- DF always manages these two; there is no per-target toggle
            point   = rec.point or "CENTER",   -- an offset from UIParent CENTER by default
            -- The DandersMover anchor block, when the container is glued to another
            -- addon's element. nil = free screen placement, and then x/y are a screen
            -- position exactly as they always were. A COPY: callers must go through
            -- SetPosition, and there is no public way to set an anchor yet.
            anchor  = rec.anchor and {
                target = rec.anchor.target, mode = rec.anchor.mode,
                edge = rec.anchor.edge, align = rec.anchor.align,
                point = rec.anchor.point, relPoint = rec.anchor.relPoint,
                offsetX = rec.anchor.offsetX, offsetY = rec.anchor.offsetY,
            } or nil,
            read    = function()
                local r = DF:GetPositionRecord(id)
                return tonumber(r.x) or 0, tonumber(r.y) or 0
            end,
            -- ☠ RAID MUST OFFER THE WRITE TO AutoProfilesUI FIRST, exactly as the drag
            -- handler does. While an auto layout drives the frames it OWNS the position,
            -- and writing raidAnchorX/Y straight to the db moves the BASE anchors
            -- underneath it — the frames do not move, and the user's base position is
            -- quietly corrupted instead. That routing now lives inside
            -- DF:SetPositionRecord, which is also what DragMover:OnDragStop and the
            -- DandersMover bridge call — one funnel, so the three cannot drift.
            write   = function(x, y)
                local r = DF:GetPositionRecord(id)
                DF:SetPositionRecord(id, { point = r.point or "CENTER", x = x, y = y,
                                           anchor = r.anchor }, "API:SetPosition")
                if id == "raid" then
                    if DF.UpdateRaidContainerPosition then DF:UpdateRaidContainerPosition() end
                else
                    if DF.UpdateContainerPosition then DF:UpdateContainerPosition() end
                end
            end,
        }
    end

    local setIndex = id:match("^" .. API_PINNED_PREFIX .. "(%d+)$")
    if setIndex then
        setIndex = tonumber(setIndex)
        local pf = DF.PinnedFrames
        if not (pf and pf.GetSetForPosition) then return nil end
        if not setIndex or setIndex < 1 or setIndex > (pf.MAX_SETS or 0) then return nil end
        local set = pf:GetSetForPosition(setIndex)
        if not set then return nil end
        -- The CURRENT mode's set (GetSetForPosition -> IsInRaid / raid test) -- the
        -- documented contract; do not change it. Read/write through the same helpers
        -- DandersMover's onChanged and the legacy handles use, so an `anchor` survives
        -- and x/y keep meaning "the glue offset while glued" (the anchorTo contract).
        local raid = pf.IsPositionTargetRaid and pf:IsPositionTargetRaid() or false
        local pos = pf.GetPositionRecord and pf:GetPositionRecord(setIndex, raid) or set.position
        if not pos then return nil end
        local label = pf.GetPositionPanelLabel and pf:GetPositionPanelLabel(setIndex)
        local a = pos.anchor
        return {
            id       = id,
            kind     = "pinned",
            setIndex = setIndex,
            label    = label or ("Pinned " .. setIndex),
            enabled  = set.enabled and true or false,
            point    = pos.point or "CENTER",
            anchorTo = pos.anchorTo,  -- nil = free screen placement (mirror of a frames `anchor`)
            anchor   = a and {
                target = a.target, mode = a.mode, edge = a.edge, align = a.align,
                point = a.point, relPoint = a.relPoint, offsetX = a.offsetX, offsetY = a.offsetY,
            } or nil,
            read     = function()
                return pf.ReadXY(pos)
            end,
            write    = function(x, y)
                if pf.CommitSetPosition then
                    pf:CommitSetPosition(setIndex, raid, { point = pos.point, x = x, y = y })
                else
                    pf.WriteXY(set, pos.point, x, y)
                    if pf.ApplySetPosition then pf:ApplySetPosition(setIndex) end
                end
            end,
        }
    end

    return nil
end

-- Every target id DF currently offers, in a stable order: party, raid, then pinned sets
-- ascending. Pinned ids appear for sets that EXIST, enabled or not — the caller decides
-- whether to show a disabled one, and a list that changed shape when a set was toggled
-- would be far harder to drive an editor from.
function DF:ListPositionTargets()
    local out = { "party", "raid" }
    local pf = DF.PinnedFrames
    if pf and pf.GetSetForPosition then
        for i = 1, (pf.MAX_SETS or 0) do
            if pf:GetSetForPosition(i) then
                out[#out + 1] = API_PINNED_PREFIX .. i
            end
        end
    end
    return out
end
