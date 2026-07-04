local addonName, DF = ...

-- ============================================================
-- NICKNAMES - OPTIONS GUI
-- A list panel for managing nickname rules. The data is account-wide
-- (DandersFramesDB_v2.global.nicknames via DF.Nicknames:GetDB()), so
-- this page has NO party/raid switch and NO sync buttons, unlike most
-- pages. It is a thin UI over the engine in Features/Nicknames.lua:
--   Add / Save  -> NK:Add / NK:SetEntry   (auto-detects * wildcards)
--   edit button -> load row into the add fields (edit mode)
--   delete (x)  -> NK:RemoveAt
--   warning     -> NK:AnalyzeConflicts (shadowed / overlapping rules)
-- Called from Options/Options.lua via DF.BuildNicknamesPage().
--
-- Layout: this page uses the shared page masonry (Add/AddSpace) like every
-- other page. Top-level blocks are Add()'d in a single full-width ("both")
-- column; horizontal control rows are wrapped in composed containers whose
-- children keep their relative SetPoints.
-- ============================================================

local ipairs = ipairs
local format = string.format
local strfind = string.find
local tconcat = table.concat
local CreateFrame = CreateFrame
local mmax = math.max

local L = DF.L
local ICON = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

-- Human-readable text for an entry's "character / pattern" column. This is
-- also exactly what the user would type to recreate it, so edit mode reuses it.
local function patternLabel(e)
    if e.kind == "bnet" then return e.pattern or "B.net" end
    if e.kind == "wildcard" then
        if e.wild == "prefix" then return e.pattern .. "*" end
        if e.wild == "suffix" then return "*" .. e.pattern end
        return "*" .. e.pattern .. "*"
    end
    if e.realm and e.realm ~= "" then
        return e.pattern .. "-" .. e.realm
    end
    return e.pattern
end

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function indexList(t)
    local parts = {}
    for _, k in ipairs(t) do parts[#parts + 1] = "#" .. k end
    return tconcat(parts, ", ")
end

function DF.BuildNicknamesPage(guiRef, pageRef, dbRef, Add, AddSpace)
    local GUI = guiRef
    local parent = pageRef.child

    -- Rebuilt on every page entry / mode switch. The page now lays out via the
    -- shared Add() masonry, and DoBuild retires + re-adds children each build — so
    -- (unlike the old hand-positioned version) this MUST re-create its widgets each
    -- time, like every other page. Nicknames data is account-wide, so a party/raid
    -- switch simply re-renders the same content.
    local NK = DF.Nicknames

    -- Forward declarations so handlers can reference each other.
    local Refresh, updateModeHint, refreshReceived
    local editingIndex, editingKind = nil, nil
    local matchType = "exact"  -- transient: how the add/edit text is interpreted
    local draggingRow, dragOffsetY = nil, 0  -- drag-to-reorder state

    -- ===== Account-wide banner (mirrors the Settings page's global banner) =====
    Add(GUI:CreateInfoBanner(parent, {
        tone = "info",
        text = L["Nicknames are account-wide — shared across every character and profile, on both Party and Raid."],
    }), 44, "both")

    -- ===== Intro group (header + enable + description) — matches the other feature
    -- pages (e.g. Pet Frames) so the toggle isn't floating loose under the banner. =====
    AddSpace(12)
    local introGroup = GUI:CreateSettingsGroup(parent, 560)
    introGroup:AddWidget(GUI:CreateHeader(parent, L["Nickname Settings"]), 40)

    local enable = GUI:CreateCheckbox(parent, L["Enable Nicknames"], nil, nil, nil,
        function()
            local d = NK:GetDB()
            return d and d.enabled
        end,
        function(val)
            local d = NK:GetDB()
            if d then d.enabled = val and true or false end
            NK:RefreshAllFrames()
            -- Reveal/hide the rest of the page (sections + spacers) immediately.
            if pageRef.RefreshStates then pageRef:RefreshStates() end
        end)
    introGroup:AddWidget(enable, 30)

    introGroup:AddWidget(GUI:CreateLabel(parent, L["Replace character names with custom nicknames on party and raid frames."], 520), 30)
    Add(introGroup, nil, "both")

    -- Everything below the intro group is hidden when Nicknames is disabled (gated at
    -- the end of this function), so a disabled page shows only the banner + the intro
    -- group (header + Enable + description).
    local gateStart = #pageRef.children + 1
    AddSpace(12)  -- gap before the first group box

    -- ===== "Add a nickname" group box =====
    -- Bordered settings group (header inside) holding the add/edit row, the match
    -- hint, and the "Add from:" source buttons — all one unit.
    local addGroup = GUI:CreateSettingsGroup(parent, 560)
    addGroup:AddWidget(GUI:CreateHeader(parent, L["Add Nickname"]), 40)

    -- The match/character/nickname row + Add/Cancel live inside this container.
    -- Plain frame (no backdrop) — the surrounding group already supplies the border.
    local addBox = CreateFrame("Frame", nil, parent)
    addBox:SetSize(502, 64)

    -- ===== Add / edit row (inside the box) =====
    -- Match-type dropdown makes intent explicit (no hidden '*' parsing). Inline
    -- on one row: Match, then Character/text, Nickname, and the buttons.
    local matchOptions = {
        exact    = L["Exact name"],
        prefix   = L["Starts with"],
        suffix   = L["Ends with"],
        contains = L["Contains"],
        _order   = { "exact", "prefix", "suffix", "contains" },
    }
    local matchDropdown = GUI:CreateDropdown(addBox, L["Match"], matchOptions, nil, nil, nil,
        function() return matchType end,
        function(v) matchType = v or "exact"; if updateModeHint then updateModeHint() end end)
    matchDropdown:SetSize(100, 50)
    matchDropdown:SetPoint("TOPLEFT", addBox, "TOPLEFT", 0, -10)  -- flush with the group's left edge

    local charInput = GUI:CreateInput(addBox, L["Character / text"], 130)
    charInput:SetPoint("TOPLEFT", matchDropdown, "TOPRIGHT", 10, 0)

    local nickInput = GUI:CreateInput(addBox, L["Nickname"], 95)
    nickInput:SetPoint("TOPLEFT", charInput, "TOPRIGHT", 10, 0)

    local addBtn = GUI:CreateButton(addBox, L["Add"], 65, 24, nil)
    addBtn:SetPoint("LEFT", nickInput.EditBox, "RIGHT", 10, 0)

    local cancelBtn = GUI:CreateButton(addBox, L["Cancel"], 56, 24, nil)
    cancelBtn:SetPoint("LEFT", addBtn, "RIGHT", 6, 0)
    cancelBtn:Hide()

    local function clearInputs()
        charInput.EditBox:SetText("")
        nickInput.EditBox:SetText("")
        charInput.EditBox:ClearFocus()
        nickInput.EditBox:ClearFocus()
    end

    -- Enable/disable the Match dropdown + Character field. Disabled while
    -- editing a B.net rule, whose account isn't an editable text field.
    local function setAddControlsEnabled(on)
        if on then charInput.EditBox:Enable() else charInput.EditBox:Disable() end
        if matchDropdown.SetEnabled then matchDropdown:SetEnabled(on) end
    end

    -- Set the match type programmatically and refresh the dropdown text + hint.
    local function setMatchType(t)
        matchType = t or "exact"
        if matchDropdown.UpdateText then matchDropdown.UpdateText() end
        if updateModeHint then updateModeHint() end
    end

    -- Switch the add row between "add new" and "editing rule N" looks.
    local function setEditMode(on)
        if on then
            addBtn.Text:SetText(L["Save"])
            cancelBtn:Show()
        else
            addBtn.Text:SetText(L["Add"])
            cancelBtn:Hide()
            editingIndex = nil
            editingKind = nil
        end
    end

    local function commit()
        local nick = trim(nickInput.EditBox:GetText())
        if editingIndex and editingKind == "bnet" then
            -- B.net rule: only the nickname is editable.
            if nick == "" then return end
            NK:SetNickname(editingIndex, nick)
        else
            local who = trim(charInput.EditBox:GetText())
            if who == "" or nick == "" then return end  -- nothing entered; no-op
            if editingIndex then
                NK:SetEntryTyped(editingIndex, matchType, who, nick)
            else
                NK:AddTyped(matchType, who, nick)
            end
        end
        clearInputs()
        setEditMode(false)
        setMatchType("exact")
        setAddControlsEnabled(true)
        if Refresh then Refresh() end
    end

    local function enterEdit(i)
        local d = NK:GetDB()
        local e = d and d.entries[i]
        if not e then return end
        editingIndex = i
        editingKind = e.kind
        if e.kind == "bnet" then
            setMatchType("exact")
            charInput.EditBox:SetText(e.pattern or "")  -- battleTag, informational only
            setAddControlsEnabled(false)
            nickInput.EditBox:SetText(e.nickname or "")
            setEditMode(true)
            nickInput.EditBox:SetFocus()
            return
        elseif e.kind == "wildcard" then
            setAddControlsEnabled(true)
            setMatchType(e.wild)
            charInput.EditBox:SetText(e.pattern or "")
        else
            setAddControlsEnabled(true)
            setMatchType("exact")
            charInput.EditBox:SetText(patternLabel(e))
        end
        nickInput.EditBox:SetText(e.nickname or "")
        setEditMode(true)
        charInput.EditBox:SetFocus()
    end

    addBtn:SetScript("OnClick", function() commit() end)
    cancelBtn:SetScript("OnClick", function() clearInputs(); setEditMode(false); setMatchType("exact"); setAddControlsEnabled(true) end)
    charInput.EditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); commit() end)
    nickInput.EditBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); commit() end)

    -- Grey-when-disabled: addBox is a plain composed frame, so the group's
    -- disableChildrenOn can't reach its inner controls automatically. Forward a
    -- SetEnabled that dims the box and disables each interactive control. (Skipped
    -- when nothing is enabled to avoid stomping edit-mode B.net disables — the
    -- gate only ever passes false here while editing is reset on each build.)
    addBox.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1.0 or 0.5)
        if enabled then charInput.EditBox:Enable() else charInput.EditBox:Disable() end
        if enabled then nickInput.EditBox:Enable() else nickInput.EditBox:Disable() end
        if matchDropdown.SetEnabled then matchDropdown:SetEnabled(enabled) end
        if addBtn.SetEnabled then addBtn:SetEnabled(enabled) end
        if cancelBtn.SetEnabled then cancelBtn:SetEnabled(enabled) end
    end

    addGroup:AddWidget(addBox, 64)

    -- ===== Match hint (updates with the selected match type) =====
    local hint = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    hint:SetWidth(460)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.6, 0.6, 0.6, 1)  -- C_TEXT_DIM: addon-standard dim help text
    updateModeHint = function()
        if matchType == "prefix" then
            hint:SetText(L["Starts with: matches any character whose name begins with this text."])
        elseif matchType == "suffix" then
            hint:SetText(L["Ends with: matches any character whose name ends with this text."])
        elseif matchType == "contains" then
            hint:SetText(L["Contains: matches any character whose name contains this text."])
        else
            hint:SetText(L["Exact: matches only this character. Add a realm as Name-Realm."])
        end
    end
    updateModeHint()
    addGroup:AddWidget(hint, 24)

    -- ===== "Add from <source>" buttons (Phase 2 source pickers) =====
    -- Lives inside the Add-a-nickname group, beneath the hint.
    local sourceBox = CreateFrame("Frame", nil, parent)
    sourceBox:SetSize(560, 26)

    local addFromLabel = sourceBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    addFromLabel:SetPoint("LEFT", sourceBox, "LEFT", 0, 0)
    addFromLabel:SetText(L["Add from:"])
    addFromLabel:SetTextColor(0.6, 0.6, 0.6, 1)  -- C_TEXT_DIM

    local function srcButton(text, key, anchorTo)
        local b = GUI:CreateButton(sourceBox, text, 78, 22, function()
            if DF.OpenNicknamePicker then DF.OpenNicknamePicker(key) end
        end)
        if anchorTo then
            b:SetPoint("LEFT", anchorTo, "RIGHT", 6, 0)
        else
            b:SetPoint("LEFT", addFromLabel, "RIGHT", 8, 0)
        end
        return b
    end
    local bGroup = srcButton(L["Group"], "group", nil)
    local bGuild = srcButton(L["Guild"], "guild", bGroup)
    local bFriends = srcButton(L["Friends"], "friends", bGuild)
    local bBnet = srcButton(L["B.net"], "bnet", bFriends)
    -- Grey-when-disabled: dim the box + disable each source button (group gate via
    -- disableChildrenOn reaches this child through its SetEnabled).
    sourceBox.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1.0 or 0.5)
        for _, b in ipairs({ bGroup, bGuild, bFriends, bBnet }) do
            if b and b.SetEnabled then b:SetEnabled(enabled) end
        end
    end
    addGroup:AddWidget(sourceBox, 30)
    Add(addGroup, nil, "both")

    -- ===== List title + count =====
    AddSpace(8)
    local title = GUI:CreateHeader(parent, L["Saved Nicknames"])
    local countText = title:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    countText:SetPoint("LEFT", title.text, "RIGHT", 10, 0)
    countText:SetTextColor(0.5, 0.5, 0.5)
    Add(title, 30, "both")

    -- ===== List background + scroll =====
    local ROW_HEIGHT = 26
    local LIST_WIDTH = 502  -- spans the add row: Match + Character + Nickname + Add
    local LIST_HEIGHT = 230

    local listBg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    listBg:SetSize(LIST_WIDTH, LIST_HEIGHT)
    GUI:CreateElementBackdrop(listBg, { bgColor = { 0.06, 0.06, 0.06, 0.95 }, borderColor = { 0.20, 0.20, 0.20, 1 } })

    -- Column headers (just above the list border)
    local function colHeader(text, x)
        local fs = parent:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        fs:SetPoint("BOTTOMLEFT", listBg, "TOPLEFT", x, 3)
        fs:SetText(text)
        fs:SetTextColor(0.55, 0.55, 0.55)
        return fs
    end
    colHeader(L["Character"], 28)
    colHeader(L["Nickname"], 214)
    colHeader(L["Source"], 322)

    local scrollFrame = CreateFrame("ScrollFrame", nil, listBg, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", -24, 4)
    if DF.GUI and DF.GUI.StyleScrollBar then DF.GUI.StyleScrollBar(scrollFrame) end

    local scrollContent = CreateFrame("Frame", nil, scrollFrame)
    scrollContent:SetSize(LIST_WIDTH - 28, 1)
    scrollFrame:SetScrollChild(scrollContent)

    -- Grey-when-disabled support: when Nicknames is off the list dims to 0.5 and
    -- stops taking mouse input (drag/edit/delete), but stays VISIBLE in place. The
    -- page's RefreshStates calls this via listBg.disableOn (set in the gate loop).
    -- A parent's EnableMouse(false) does NOT block child frames, so we must also
    -- disable interaction on every pooled row (drag + edit/delete buttons).
    -- Forward-declared here; assigned after rowPool exists (runs at gate time).
    local applyRowsEnabled
    listBg.SetEnabled = function(self, enabled)
        local alpha = enabled and 1.0 or 0.5
        self:SetAlpha(alpha)
        self:EnableMouse(enabled)
        scrollContent:EnableMouse(enabled)
        scrollFrame:EnableMouse(enabled)
        if applyRowsEnabled then applyRowsEnabled(enabled) end
    end

    local emptyText = listBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    emptyText:SetPoint("CENTER", 0, 0)
    emptyText:SetText(L["No nickname rules yet. Add one above."])

    local rowPool = {}

    -- Block/restore interaction on every pooled row when the list is disabled.
    -- (listBg's own EnableMouse can't reach these children.) Rows are re-pooled by
    -- Refresh, which re-applies this so freshly-shown rows inherit the gate state.
    applyRowsEnabled = function(enabled)
        for _, row in ipairs(rowPool) do
            row:EnableMouse(enabled)
            if row.del then row.del:SetEnabled(enabled) end
            if row.edit then row.edit:SetEnabled(enabled) end
        end
    end

    -- Map a screen Y position to a 1-based drop index in the list.
    local function indexFromY(cursorY)
        local top = scrollContent:GetTop()
        local d = NK:GetDB()
        local n = (d and #d.entries) or 0
        if not top or n == 0 then return 1 end
        local idx = math.floor((top - cursorY) / ROW_HEIGHT) + 1
        if idx < 1 then idx = 1 elseif idx > n then idx = n end
        return idx
    end

    -- OnUpdate while dragging: float the dragged row under the cursor and
    -- reflow the other rows to leave a gap at the prospective drop slot.
    local function dragFollow(self)
        if draggingRow ~= self then return end
        local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local top = scrollContent:GetTop()
        if not top then return end
        local d = NK:GetDB()
        local n = (d and #d.entries) or 0

        local off = top - (cursorY + dragOffsetY)
        local maxOff = math.max(0, n - 1) * ROW_HEIGHT
        if off < 0 then off = 0 elseif off > maxOff then off = maxOff end
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", 0, -off)
        self:SetPoint("TOPRIGHT", 0, -off)

        local drop = indexFromY(cursorY)
        local pos = 0
        for i = 1, n do
            local r = rowPool[i]
            if r and r ~= self and r:IsShown() then
                pos = pos + 1
                if pos == drop then pos = pos + 1 end  -- leave the gap
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", 0, -((pos - 1) * ROW_HEIGHT))
                r:SetPoint("TOPRIGHT", 0, -((pos - 1) * ROW_HEIGHT))
            end
        end
    end

    -- Lazily create the pooled row at slot `slot`. Handlers read the row's
    -- CURRENT entry index from row.entryIndex (never a captured stale value).
    local function getRow(slot)
        local row = rowPool[slot]
        if row then return row end

        row = CreateFrame("Frame", nil, scrollContent)
        row:SetSize(LIST_WIDTH - 30, ROW_HEIGHT)
        row:EnableMouse(true)  -- for drag-to-reorder; child controls capture their own clicks

        -- subtle highlight shown only while this row is being dragged
        row.dragHL = row:CreateTexture(nil, "BACKGROUND")
        row.dragHL:SetAllPoints()
        row.dragHL:SetColorTexture(1, 1, 1, 0.08)
        row.dragHL:Hide()

        -- drag grip affordance (the whole row is draggable; this is the hint)
        row.grip = row:CreateTexture(nil, "ARTWORK")
        row.grip:SetSize(12, 12)
        row.grip:SetPoint("LEFT", 2, 0)
        row.grip:SetTexture(ICON .. "reorder")
        row.grip:SetVertexColor(0.4, 0.4, 0.4)

        -- priority number
        row.numFS = row:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
        row.numFS:SetPoint("LEFT", row.grip, "RIGHT", 2, 0)
        row.numFS:SetWidth(16)
        row.numFS:SetJustifyH("RIGHT")

        -- character / pattern
        row.charFS = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        row.charFS:SetPoint("LEFT", row.numFS, "RIGHT", 4, 0)
        row.charFS:SetWidth(150)
        row.charFS:SetJustifyH("LEFT")

        -- arrow (native chevron texture, not a font glyph)
        row.arrow = row:CreateTexture(nil, "OVERLAY")
        row.arrow:SetSize(10, 10)
        row.arrow:SetPoint("LEFT", row.charFS, "RIGHT", 2, 0)
        row.arrow:SetTexture(ICON .. "chevron_right")
        row.arrow:SetVertexColor(0.5, 0.5, 0.5)

        -- override / conflict indicator, inlined to the LEFT of the nickname
        -- (the warning is about which nickname wins). Uses the addon's native
        -- warning triangle (warning.tga, as in Core/Dialogs/Aura Designer),
        -- colour-coded by severity in Refresh().
        row.flag = CreateFrame("Button", nil, row)
        row.flag:SetSize(16, 16)
        row.flag:SetPoint("LEFT", row.arrow, "RIGHT", 4, 0)
        row.flag.tex = row.flag:CreateTexture(nil, "OVERLAY")
        row.flag.tex:SetSize(12, 12)
        row.flag.tex:SetPoint("CENTER")
        row.flag.tex:SetTexture(ICON .. "warning")
        row.flag:SetScript("OnEnter", function(self)
            if not self.tipTitle then return end
            GUI:ShowTooltip(self, {
                title = self.tipTitle,
                lines = self.tipBody and { self.tipBody } or nil,
            })
        end)
        row.flag:SetScript("OnLeave", function() GUI:HideTooltip() end)

        -- nickname
        row.nickFS = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        row.nickFS:SetPoint("LEFT", row.flag, "RIGHT", 4, 0)
        row.nickFS:SetWidth(100)
        row.nickFS:SetJustifyH("LEFT")

        -- source
        row.srcFS = row:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
        row.srcFS:SetPoint("LEFT", row.nickFS, "RIGHT", 8, 0)
        row.srcFS:SetWidth(56)
        row.srcFS:SetJustifyH("LEFT")

        -- delete: danger tone gives a red icon at rest AND a red hover wash/border
        -- (plain CreateIconButton hovered to the blue accent), matching every other
        -- delete in the GUI.
        row.del = CreateFrame("Button", nil, row, "BackdropTemplate")
        GUI:StyleButton(row.del, {
            width = 26, height = 22, tone = "danger",
            icon = { texture = ICON .. "delete", size = 12 },
        })
        row.del.Icon:ClearAllPoints()
        row.del.Icon:SetPoint("CENTER")
        row.del:SetPoint("RIGHT", -2, 0)
        row.del:SetScript("OnClick", function()
            local i = row.entryIndex
            if not i then return end
            if editingIndex then clearInputs(); setEditMode(false) end
            NK:RemoveAt(i)
            if Refresh then Refresh() end
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)

        -- edit (neutral) to the left of delete
        row.edit = GUI:CreateIconButton(row, "edit", "", 26, 22, function()
            if row.entryIndex then enterEdit(row.entryIndex) end
        end, 12)
        row.edit:SetPoint("RIGHT", row.del, "LEFT", -4, 0)
        row.edit.Icon:ClearAllPoints()
        row.edit.Icon:SetPoint("CENTER")

        -- ----- drag-to-reorder (with hover affordance) -----
        row:SetScript("OnEnter", function(self)
            if draggingRow then return end
            self.grip:SetVertexColor(0.85, 0.85, 0.85)
            self.dragHL:Show()
        end)
        row:SetScript("OnLeave", function(self)
            if draggingRow == self then return end
            self.grip:SetVertexColor(0.4, 0.4, 0.4)
            self.dragHL:Hide()
        end)
        row:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" or not self.entryIndex then return end
            draggingRow = self
            local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            dragOffsetY = (self:GetTop() or 0) - cursorY
            self:SetFrameLevel(scrollContent:GetFrameLevel() + 10)
            self.dragHL:Show()
            self.grip:SetVertexColor(1, 1, 1)
            self:SetScript("OnUpdate", dragFollow)
        end)
        row:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" or draggingRow ~= self then return end
            self:SetScript("OnUpdate", nil)
            local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local drop = indexFromY(cursorY)
            local from = self.entryIndex
            draggingRow = nil
            self.dragHL:Hide()
            self.grip:SetVertexColor(0.4, 0.4, 0.4)
            self:SetFrameLevel(scrollContent:GetFrameLevel() + 1)
            if from and drop ~= from then
                NK:MoveEntry(from, drop)   -- reorders + triggers Refresh via onChange
            elseif Refresh then
                Refresh()                  -- snap back if no move
            end
        end)

        rowPool[slot] = row
        return row
    end

    Refresh = function()
        local data = NK:GetDB()
        local entries = (data and data.entries) or {}
        local n = #entries
        local conflicts = NK:AnalyzeConflicts()

        emptyText:SetShown(n == 0)
        local overridden = 0
        for _, c in ipairs(conflicts) do
            if c.shadowedBy then overridden = overridden + 1 end
        end
        local baseCount = (n == 1) and L["1 rule"] or format(L["%d rules"], n)
        if overridden > 0 then
            countText:SetText(baseCount .. "  |cffff8888" .. format(L["%d overridden"], overridden) .. "|r")
        else
            countText:SetText(baseCount)
        end

        for _, r in ipairs(rowPool) do r:Hide() end

        for i, e in ipairs(entries) do
            local row = getRow(i)
            row.entryIndex = i
            row.numFS:SetText(i .. ".")
            row.charFS:SetText(patternLabel(e))
            row.nickFS:SetText(e.nickname or "")
            row.srcFS:SetText(e.source or "")

            local c = conflicts[i]
            if e.needsRelink then
                row.flag.tex:SetVertexColor(1, 0.55, 0.1)  -- orange = needs re-link
                row.flag.tipTitle = L["Needs re-link"]
                row.flag.tipBody = L["This Battle.net friend could not be matched after an update. Remove this rule and add them again."]
                row.flag:Show()
                row.charFS:SetTextColor(0.5, 0.5, 0.5)  -- dim: this rule is inactive
                row.nickFS:SetTextColor(0.5, 0.5, 0.5)
            elseif c and c.shadowedBy then
                row.flag.tex:SetVertexColor(1, 0.35, 0.35)  -- red = overridden / never applies
                row.flag.tipTitle = L["Overridden"]
                row.flag.tipBody = format(
                    L["Rule #%d (%s) is higher in the list and already matches these names, so this rule never applies. Move it above #%d to use it."],
                    c.shadowedBy, patternLabel(entries[c.shadowedBy]), c.shadowedBy)
                row.flag:Show()
                row.charFS:SetTextColor(0.5, 0.5, 0.5)  -- dim: this rule is inactive
                row.nickFS:SetTextColor(0.5, 0.5, 0.5)
            elseif c and #c.overlaps > 0 then
                row.flag.tex:SetVertexColor(1, 0.95, 0.2)  -- yellow = overlap (informational)
                row.flag.tipTitle = L["Overlapping rule"]
                row.flag.tipBody = format(
                    L["Overlaps with rule(s) %s. For names they share, the rule higher in the list wins."],
                    indexList(c.overlaps))
                row.flag:Show()
                row.charFS:SetTextColor(0.9, 0.9, 0.9)
                row.nickFS:SetTextColor(0.9, 0.9, 0.9)
            else
                row.flag:Hide()
                row.flag.tipTitle = nil
                row.flag.tipBody = nil
                row.charFS:SetTextColor(0.9, 0.9, 0.9)
                row.nickFS:SetTextColor(0.9, 0.9, 0.9)
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
            row:Show()
        end

        scrollContent:SetHeight(mmax(1, n * ROW_HEIGHT))
        -- Re-apply the disabled gate so freshly-pooled rows inherit it (Refresh
        -- rebuilds rows, which would otherwise come back fully interactive).
        applyRowsEnabled((data and data.enabled) and true or false)
        if refreshReceived then refreshReceived() end
    end

    pageRef._nkRefresh = Refresh

    -- The column headers sit just above listBg's TOP border — reserve a row for
    -- them in the flow so they clear the title above instead of colliding with it.
    AddSpace(18)
    Add(listBg, LIST_HEIGHT, "both")

    -- ===== Priority note (light) — sits UNDER the list, mirroring the "Exact: …"
    -- hint that sits under the "Add a nickname" box. =====
    local priorityNote = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    priorityNote:SetJustifyH("LEFT")
    priorityNote:SetTextColor(0.6, 0.6, 0.6, 1)  -- C_TEXT_DIM, matches the page's other hints
    priorityNote:SetText(L["Rules are checked top to bottom — the first one that matches a name wins. Drag a row by its grip to change priority."])
    Add(priorityNote, 24, "both")
    AddSpace(12)  -- gap before the Marker box

    -- ===== Marker (decoration sub-feature) — placed after the list since adding/
    -- viewing nicknames is the primary task; the marker is secondary decoration. =====
    -- "Mark nicknames" is the parent toggle; the two dropdowns are its sub-options,
    -- indented beneath it and greyed out when marking is off so it reads as a unit.
    local markGroup = GUI:CreateSettingsGroup(parent, 560)
    markGroup:AddWidget(GUI:CreateHeader(parent, L["Marker"]), 40)

    -- Forward-declared so the toggle's callback can enable/disable them.
    local markScopeDD, markStyleDD
    local function updateMarkControls()
        local d = NK:GetDB()
        local on = (d and d.markEnabled) and true or false
        if markScopeDD and markScopeDD.SetEnabled then markScopeDD:SetEnabled(on) end
        if markStyleDD and markStyleDD.SetEnabled then markStyleDD:SetEnabled(on) end
    end

    local markEnable = GUI:CreateCheckbox(parent, L["Mark nicknames"], nil, nil, nil,
        function() local d = NK:GetDB(); return d and d.markEnabled end,
        function(val)
            local d = NK:GetDB(); if d then d.markEnabled = val and true or false end
            updateMarkControls()
            NK:RefreshAllFrames()
        end)
    markGroup:AddWidget(markEnable, 30)

    -- The two dropdowns sit side-by-side in a composed container the group
    -- stacks as a single row (flush-left, like the rest of the box).
    local markDDRow = CreateFrame("Frame", nil, parent)
    markDDRow:SetSize(560, 56)

    local markScopeOpts = {
        all = L["All nicknames"], mine = L["My added"], received = L["Received only"],
        _order = { "all", "mine", "received" },
    }
    markScopeDD = GUI:CreateDropdown(markDDRow, L["Apply to"], markScopeOpts, nil, nil, nil,
        function() local d = NK:GetDB(); return d and d.markScope or "all" end,
        function(v) local d = NK:GetDB(); if d then d.markScope = v end; NK:RefreshAllFrames() end)
    markScopeDD:SetSize(150, 50)
    markScopeDD:SetPoint("TOPLEFT", markDDRow, "TOPLEFT", 0, 0)   -- flush left; grey-when-off conveys the dependency

    local markStyleOpts = {
        brackets = L["Brackets  [name]"],
        parens   = L["Parentheses  (name)"],
        angle    = L["Angle  <name>"],
        asterisk = L["Asterisk  name*"],
        _order   = { "brackets", "parens", "angle", "asterisk" },
    }
    markStyleDD = GUI:CreateDropdown(markDDRow, L["Marker style"], markStyleOpts, nil, nil, nil,
        function() local d = NK:GetDB(); return d and d.markStyle or "brackets" end,
        function(v) local d = NK:GetDB(); if d then d.markStyle = v end; NK:RefreshAllFrames() end)
    markStyleDD:SetSize(190, 50)
    markStyleDD:SetPoint("TOPLEFT", markScopeDD, "TOPRIGHT", 10, 0)
    updateMarkControls()   -- set initial enabled/greyed state from saved value
    -- Grey-when-disabled: the group gate (disableChildrenOn) reaches the composed
    -- dropdown row through this SetEnabled. When re-enabling, defer to the marker's
    -- own toggle state (markEnabled) so we don't un-grey sub-options the user left off.
    markDDRow.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1.0 or 0.5)
        if enabled then
            updateMarkControls()
        else
            if markScopeDD and markScopeDD.SetEnabled then markScopeDD:SetEnabled(false) end
            if markStyleDD and markStyleDD.SetEnabled then markStyleDD:SetEnabled(false) end
        end
    end
    markGroup:AddWidget(markDDRow, 60)
    Add(markGroup, nil, "both")
    AddSpace(12)  -- gap before the Sharing & Sync box

    -- ===== Sharing & Sync =====
    local shareGroup = GUI:CreateSettingsGroup(parent, 560)
    shareGroup:AddWidget(GUI:CreateHeader(parent, L["Sharing & Sync"]), 40)

    local shareBox = CreateFrame("Frame", nil, parent)
    shareBox:SetSize(560, 80)

    local selfInput = GUI:CreateInput(shareBox, L["Your nickname (broadcast)"], 160)
    selfInput:SetPoint("TOPLEFT", shareBox, "TOPLEFT", 0, 0)
    do local d = NK:GetDB(); selfInput.EditBox:SetText((d and d.selfNick) or "") end
    local function saveSelfNick()
        local d = NK:GetDB(); if not d then return end
        d.selfNick = (selfInput.EditBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        selfInput.EditBox:ClearFocus()
        if DF.NicknamesComm then DF.NicknamesComm:BroadcastSelfNick() end
    end
    selfInput.EditBox:SetScript("OnEnterPressed", function() saveSelfNick() end)
    selfInput.EditBox:SetScript("OnEditFocusLost", function() saveSelfNick() end)

    local shareChannelOpts = {
        off = L["Off"], raid = L["Raid/Party"], guild = L["Guild"], both = L["Both"],
        _order = { "off", "raid", "guild", "both" },
    }
    local shareViaDD = GUI:CreateDropdown(shareBox, L["Share via"], shareChannelOpts, nil, nil, nil,
        function() local d = NK:GetDB(); return d and d.shareVia or "off" end,
        function(v) local d = NK:GetDB(); if d then d.shareVia = v end
            if DF.NicknamesComm then DF.NicknamesComm:BroadcastSelfNick() end end)
    shareViaDD:SetSize(120, 50)
    shareViaDD:SetPoint("TOPLEFT", selfInput, "TOPRIGHT", 12, 0)

    local acceptDD = GUI:CreateDropdown(shareBox, L["Accept from"], shareChannelOpts, nil, nil, nil,
        function() local d = NK:GetDB(); return d and d.acceptFrom or "off" end,
        function(v) local d = NK:GetDB(); if d then d.acceptFrom = v end end)
    acceptDD:SetSize(120, 50)
    acceptDD:SetPoint("TOPLEFT", shareViaDD, "TOPRIGHT", 12, 0)

    local autoCB = GUI:CreateCheckbox(shareBox, L["Auto-share on group join"], nil, nil, nil,
        function() local d = NK:GetDB(); return d and d.autoSync end,
        function(val) local d = NK:GetDB(); if d then d.autoSync = val and true or false end end)
    autoCB:SetPoint("TOPLEFT", selfInput, "BOTTOMLEFT", 0, -10)

    local shareNowBtn = GUI:CreateButton(shareBox, L["Share now"], 90, 22, function()
        if DF.NicknamesComm then DF.NicknamesComm:BroadcastSelfNick() end
    end)
    shareNowBtn:SetPoint("LEFT", autoCB, "RIGHT", 20, 0)

    local requestBtn = GUI:CreateButton(shareBox, L["Request"], 90, 22, function()
        if DF.NicknamesComm then DF.NicknamesComm:RequestFromGroup() end
    end)
    requestBtn:SetPoint("LEFT", shareNowBtn, "RIGHT", 8, 0)
    -- Grey-when-disabled: dim the box + disable each control so the group gate
    -- (disableChildrenOn) greys the whole Sharing & Sync row in place.
    shareBox.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1.0 or 0.5)
        if enabled then selfInput.EditBox:Enable() else selfInput.EditBox:Disable() end
        for _, c in ipairs({ shareViaDD, acceptDD, autoCB, shareNowBtn, requestBtn }) do
            if c and c.SetEnabled then c:SetEnabled(enabled) end
        end
    end
    shareGroup:AddWidget(shareBox, 80)
    Add(shareGroup, nil, "both")

    -- ===== Received nicknames (shared by others; separate from your list) =====
    AddSpace(12)
    local recvTitle = GUI:CreateHeader(parent, L["Received Nicknames"])
    local recvCount = recvTitle:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    recvCount:SetPoint("LEFT", recvTitle.text, "RIGHT", 10, 0)
    recvCount:SetTextColor(0.5, 0.5, 0.5)
    Add(recvTitle, 30, "both")

    local recvBg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    recvBg:SetSize(LIST_WIDTH, 120)
    GUI:CreateElementBackdrop(recvBg, { bgColor = { 0.06, 0.06, 0.06, 0.95 }, borderColor = { 0.20, 0.20, 0.20, 1 } })

    local recvScroll = CreateFrame("ScrollFrame", nil, recvBg, "ScrollFrameTemplate")
    recvScroll:SetPoint("TOPLEFT", 4, -4)
    recvScroll:SetPoint("BOTTOMRIGHT", -24, 4)
    if DF.GUI and DF.GUI.StyleScrollBar then DF.GUI.StyleScrollBar(recvScroll) end

    local recvContent = CreateFrame("Frame", nil, recvScroll)
    recvContent:SetSize(LIST_WIDTH - 28, 1)
    recvScroll:SetScrollChild(recvContent)

    -- Grey-when-disabled support (mirrors listBg): dim to 0.5 + drop mouse input
    -- when Nicknames is off, but stay visible. Driven by recvBg.disableOn below.
    -- As with the saved list, a parent's EnableMouse(false) doesn't reach child
    -- frames, so we must disable each received row's interactive controls too.
    -- Forward-declared; assigned after recvRows exists (runs at gate time).
    local applyRecvRowsEnabled
    recvBg.SetEnabled = function(self, enabled)
        local alpha = enabled and 1.0 or 0.5
        self:SetAlpha(alpha)
        self:EnableMouse(enabled)
        recvContent:EnableMouse(enabled)
        recvScroll:EnableMouse(enabled)
        if applyRecvRowsEnabled then applyRecvRowsEnabled(enabled) end
    end

    local recvEmpty = recvBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    recvEmpty:SetPoint("CENTER", 0, 0)
    recvEmpty:SetText(L["No nicknames received yet."])

    local recvRows = {}

    -- Block/restore interaction on every received row when the list is disabled.
    -- (recvBg's own EnableMouse can't reach these children.) Re-applied by
    -- refreshReceived so freshly-pooled rows inherit the gate state.
    local function applyRecvRowsEnabledImpl(enabled)
        for _, r in ipairs(recvRows) do
            r:EnableMouse(enabled)
            if r.del then r.del:SetEnabled(enabled) end
            if r.block then r.block:SetEnabled(enabled) end
            if r.status then r.status:EnableMouse(enabled) end
        end
    end
    applyRecvRowsEnabled = applyRecvRowsEnabledImpl

    local function getRecvRow(i)
        local r = recvRows[i]
        if r then return r end
        r = CreateFrame("Frame", nil, recvContent)
        r:SetSize(LIST_WIDTH - 30, ROW_HEIGHT)

        -- blocked status indicator (left; shown only when blocked)
        r.status = CreateFrame("Button", nil, r)
        r.status:SetSize(14, 14)
        r.status:SetPoint("LEFT", 4, 0)
        r.status.tex = r.status:CreateTexture(nil, "OVERLAY")
        r.status.tex:SetAllPoints()
        r.status.tex:SetTexture(ICON .. "warning")
        r.status.tex:SetVertexColor(1, 0.35, 0.35)
        r.status:SetScript("OnEnter", function(self)
            if not self.tip then return end
            GUI:ShowTooltip(self, { title = self.tip })
        end)
        r.status:SetScript("OnLeave", function() GUI:HideTooltip() end)

        r.who = r:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        r.who:SetPoint("LEFT", r.status, "RIGHT", 4, 0); r.who:SetWidth(170); r.who:SetJustifyH("LEFT")
        r.who:SetTextColor(0.8, 0.8, 0.8)
        r.arrow = r:CreateTexture(nil, "OVERLAY")
        r.arrow:SetSize(10, 10); r.arrow:SetPoint("LEFT", r.who, "RIGHT", 2, 0)
        r.arrow:SetTexture(ICON .. "chevron_right"); r.arrow:SetVertexColor(0.5, 0.5, 0.5)
        r.nick = r:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        r.nick:SetPoint("LEFT", r.arrow, "RIGHT", 6, 0); r.nick:SetWidth(110); r.nick:SetJustifyH("LEFT")
        r.nick:SetTextColor(0.9, 0.9, 0.9)

        r.del = GUI:CreateIconButton(r, "close", "", 24, 20, function()
            if r.sender then NK:RemoveReceived(r.sender) end
        end, 11)
        r.del:SetPoint("RIGHT", -2, 0); r.del.Icon:ClearAllPoints(); r.del.Icon:SetPoint("CENTER")

        -- block / unblock toggle (left of dismiss)
        r.block = GUI:CreateIconButton(r, "lock_open", "", 24, 20, function()
            if not r.sender then return end
            if r.isBlocked then NK:UnblockSender(r.sender) else NK:BlockSender(r.sender) end
        end, 12)
        r.block:SetPoint("RIGHT", r.del, "LEFT", -4, 0)
        r.block.Icon:ClearAllPoints(); r.block.Icon:SetPoint("CENTER")

        recvRows[i] = r
        return r
    end

    local RECV_REASON_TEXT = {
        profanity = L["Blocked: contains a filtered word"],
        escape    = L["Blocked: contained formatting codes"],
        toolong   = L["Blocked: too long"],
        empty     = L["Blocked: empty"],
        user      = L["Blocked by you"],
    }

    refreshReceived = function()
        local list = NK:GetReceivedList()
        table.sort(list, function(a, b) return (a.sender or "") < (b.sender or "") end)
        local n = #list
        recvCount:SetText(n == 1 and L["1 received"] or format(L["%d received"], n))
        recvEmpty:SetShown(n == 0)
        for _, r in ipairs(recvRows) do r:Hide() end
        for i, item in ipairs(list) do
            local r = getRecvRow(i)
            r.sender = item.sender
            r.isBlocked = item.blocked and true or false
            r.who:SetText(item.sender or "?")
            r.nick:SetText(item.nick or "")
            if item.blocked then
                r.who:SetTextColor(0.5, 0.5, 0.5)
                r.nick:SetTextColor(0.5, 0.5, 0.5)
                r.status:Show()
                r.status.tip = RECV_REASON_TEXT[item.reason] or L["Blocked"]
                if item.reason == "user" then
                    r.block.Icon:SetTexture(ICON .. "lock"); r.block.Icon:SetVertexColor(1, 0.8, 0.2); r.block:Show()
                else
                    r.block:Hide()  -- filter-blocked: not user-reversible here
                end
            else
                r.who:SetTextColor(0.8, 0.8, 0.8)
                r.nick:SetTextColor(0.9, 0.9, 0.9)
                r.status:Hide(); r.status.tip = nil
                r.block.Icon:SetTexture(ICON .. "lock_open"); r.block.Icon:SetVertexColor(0.6, 0.6, 0.6); r.block:Show()
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
            r:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)
            r:Show()
        end
        recvContent:SetHeight(mmax(1, n * ROW_HEIGHT))
        -- Re-apply the disabled gate so freshly-pooled rows inherit it.
        local d = NK:GetDB()
        applyRecvRowsEnabled((d and d.enabled) and true or false)
    end

    Add(recvBg, 120, "both")

    -- ===== Name precedence (only shown when NSRT can also manage our names) =====
    -- Northern Sky Raid Tools can also be set to put nicknames on DandersFrames
    -- frames; when both are active they fight. This mirrors the one-time conflict
    -- popup (Features/Nicknames.lua) so the choice can be changed here later.
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("NorthernSkyRaidTools") then
        AddSpace(12)  -- gap so the Received list box doesn't merge into this one
        local precGroup = GUI:CreateSettingsGroup(parent, 560)
        precGroup:AddWidget(GUI:CreateHeader(parent, L["Name Precedence"]), 40)

        local precBox = CreateFrame("Frame", nil, parent)
        precBox:SetSize(560, 80)

        local precDesc = precBox:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
        precDesc:SetPoint("TOPLEFT", precBox, "TOPLEFT", 0, 0)
        precDesc:SetWidth(LIST_WIDTH)
        precDesc:SetJustifyH("LEFT")
        precDesc:SetText(L["Northern Sky Raid Tools can also show nicknames on DandersFrames frames. Choose which one decides the names shown here."])

        local precOpts = {
            self = "DandersFrames", nsrt = "Northern Sky Raid Tools",
            _order = { "self", "nsrt" },
        }
        local precDD = GUI:CreateDropdown(precBox, L["Names on frames decided by"], precOpts, nil, nil, nil,
            function() local d = NK:GetDB(); return (d and d.framePrecedence == "nsrt") and "nsrt" or "self" end,
            function(v)
                local d = NK:GetDB(); if d then d.framePrecedence = v end
                NK:RefreshAllFrames()
            end)
        precDD:SetSize(220, 50)
        precDD:SetPoint("TOPLEFT", precDesc, "BOTTOMLEFT", 0, -8)  -- flush left, like every other box
        -- Grey-when-disabled: dim the box + disable the dropdown (group gate reaches
        -- this composed child through SetEnabled).
        precBox.SetEnabled = function(self, enabled)
            self:SetAlpha(enabled and 1.0 or 0.5)
            if precDD.SetEnabled then precDD:SetEnabled(enabled) end
        end
        precGroup:AddWidget(precBox, 80)
        Add(precGroup, nil, "both")
    end

    -- When Nicknames is disabled, GREY (don't hide) everything below the intro group
    -- so the whole page stays visible but reads as inert: the banner + intro group
    -- (header + Enable + description) stay fully interactive. Everything Add()'d after
    -- the intro group (captured by gateStart) is greyed in place:
    --   * settings groups   -> disableChildrenOn (greys every child but the header)
    --   * SetEnabled widgets -> disableOn (the control greys itself)
    --   * the list frames    -> disableOn drives the SetEnabled added above (alpha 0.5
    --                           + mouse off); headers/labels/spacers stay full-colour.
    -- Composes with any existing disableChildrenOn/disableOn. RefreshStates (run on
    -- build + on the Enable toggle) applies it.
    local function NicknamesDisabled()
        local d = NK:GetDB()
        return not (d and d.enabled)
    end
    for i = gateStart, #pageRef.children do
        local w = pageRef.children[i]
        if w.isSettingsGroup then
            local prev = w.disableChildrenOn
            w.disableChildrenOn = function(db) return NicknamesDisabled() or (prev and prev(db)) end
        elseif w.SetEnabled then
            local prev = w.disableOn
            w.disableOn = function(db) return NicknamesDisabled() or (prev and prev(db)) end
        end
        -- else: labels/spacers (no SetEnabled) stay visible at full colour.
    end

    -- Keep this panel in sync with changes made anywhere (e.g. incoming shares).
    NK.onChange = Refresh
    Refresh()
end
