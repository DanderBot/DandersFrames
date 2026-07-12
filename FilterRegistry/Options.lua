local addonName, DF = ...

-- ============================================================
-- FILTER REGISTRY - FILTER DESIGNER GUI
-- Two-column editor for the buff filter registry: built-in
-- preset categories (per-profile enable/disable overrides) and
-- account-wide custom filters. Called from Options/Options.lua
-- via DF.BuildFilterDesignerPage().
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local format = string.format
local tinsert = table.insert
local tsort = table.sort
local mmax = math.max
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetBuildInfo = GetBuildInfo
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local LOCALIZED_CLASS_NAMES_MALE = LOCALIZED_CLASS_NAMES_MALE

local L = DF.L

local FALLBACK_ICON = 134400 -- question mark

local function Trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- ============================================================
-- NAME PROMPT + DELETE CONFIRM
-- Same StaticPopup idiom as the Designer preset bar in GUI/GUI.lua:
-- structural dialog definitions here, per-call handlers assigned in
-- the launchers (the StaticPopup `data` field and the editbox field
-- name both vary across client versions, so we avoid relying on them).
-- ============================================================

StaticPopupDialogs["DANDERSFRAMES_FILTER_NAME"] = {
    text = "%s",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    editBoxWidth = 220,
    maxLetters = 40,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["DANDERSFRAMES_FILTER_DELETE"] = {
    text = "%s",
    button1 = DELETE or "Delete",
    button2 = CANCEL or "Cancel",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function PromptFilterName(titleText, default, callback)
    local dialog = StaticPopupDialogs["DANDERSFRAMES_FILTER_NAME"]
    dialog.OnShow = function(self)
        local eb = self.EditBox or self.editBox or (self.GetEditBox and self:GetEditBox())
        if eb then
            eb:SetText(default or "")
            eb:HighlightText()
            eb:SetFocus()
        end
    end
    dialog.OnAccept = function(self)
        local eb = self.EditBox or self.editBox or (self.GetEditBox and self:GetEditBox())
        if callback and eb then callback(eb:GetText()) end
    end
    dialog.EditBoxOnEnterPressed = function(self)
        if callback then callback(self:GetText()) end
        local p = self:GetParent()
        if p then p:Hide() end
    end
    StaticPopup_Show("DANDERSFRAMES_FILTER_NAME", titleText)
end

local function ConfirmDeleteFilter(displayName, onAccept)
    local dialog = StaticPopupDialogs["DANDERSFRAMES_FILTER_DELETE"]
    dialog.OnAccept = function() onAccept() end
    StaticPopup_Show("DANDERSFRAMES_FILTER_DELETE",
        format(L["Delete filter \"%s\"? It will also be removed from every profile that uses it."], displayName))
end

-- Deleting a custom filter must also unhook it from every profile's
-- per-mode selections (both the buff and defensive rows), or stale ids
-- linger in SavedVariables forever. Nil-safe against profiles that
-- predate the selection tables or are missing a mode entirely.
local function ScrubDeletedFilter(cfId)
    local sv = DandersFramesDB_v2
    local profiles = sv and sv.profiles
    if type(profiles) ~= "table" then return end
    for _, profile in pairs(profiles) do
        if type(profile) == "table" then
            for i = 1, 2 do
                local mode = (i == 1) and profile.party or profile.raid
                if type(mode) == "table" then
                    local sel = mode.buffFilterSelection
                    if sel and sel.customs then sel.customs[cfId] = nil end
                    sel = mode.defensiveFilterSelection
                    if sel and sel.customs then sel.customs[cfId] = nil end
                end
            end
        end
    end
end

-- Fixed grouping order for the spell list (token-alphabetical); records with
-- class == "ALL" (or no class) group last under L["All Classes"].
local CLASS_ORDER = {
    "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER", "MAGE",
    "MONK", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}

-- Localized class display names via Blizzard's global (codebase precedent:
-- TextDesigner/DataSource.lua). Covers Death Knight / Demon Hunter / Evoker.
local function ClassDisplayName(token)
    if token == "ALL" then return L["All Classes"] end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
end

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildFilterDesignerPage(guiRef, pageRef, dbRef)
    -- Build frames once; subsequent calls just refresh widget data.
    -- DoBuild wipes child.ThemeListeners and retires Add()ed children on every
    -- rebuild, so the guard path re-adopts the height spacer and re-registers
    -- the theme listener before refreshing.
    if pageRef._filterDesignerBuilt then
        local p = pageRef.child
        p.ThemeListeners = p.ThemeListeners or {}
        table.insert(p.ThemeListeners, pageRef._fdThemeListener)
        if pageRef._fdSpacer and pageRef.children then
            pageRef._fdSpacer:SetParent(p)
            table.insert(pageRef.children, pageRef._fdSpacer)
        end
        if pageRef._fdRefreshAll then pageRef._fdRefreshAll() end
        return
    end
    pageRef._filterDesignerBuilt = true

    local GUI = guiRef
    local parent = pageRef.child
    local R = DF.FilterRegistry

    -- ========== LAYOUT CONSTANTS ==========
    local PANEL_H = 490
    local LEFT_W = 240
    local LEFT_ROW_H = 24
    local SECTION_H = 22
    local SPELL_ROW_H = 26
    local CLASS_HEADER_H = 22

    -- ========== STATE ==========
    local selKind = "preset" -- "preset" | "custom"
    local selKey = R.Categories[1] and R.Categories[1].key
    local searchText = "" -- lowercased query

    local RefreshLeft, RefreshRight, RefreshAll, UpdateActionStates -- forward declarations

    -- ========== CHANGE PROPAGATION ==========
    -- The aura pipeline's reaction to a filter-definition change. Mirrors the
    -- local DirectFilterChanged on the Aura Filters page (not visible here).
    local function DirectFilterChangedProxy()
        if DF.RebuildDirectFilterStrings then
            DF:RebuildDirectFilterStrings()
        end
        if DF.InvalidateAuraLayout then
            DF:InvalidateAuraLayout()
        end
    end

    -- ========== CUSTOM FILTER HELPERS ==========
    -- Stable name-sorted id list (the store is id-keyed)
    local function SortedCustomIDs()
        local ids = {}
        for cfId in pairs(R:GetStore().customFilters) do
            ids[#ids + 1] = cfId
        end
        tsort(ids, function(a, b)
            local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
            local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
            if na ~= nb then return na < nb end
            return a < b
        end)
        return ids
    end

    local function CustomSpellCount(f)
        local n = 0
        for _ in pairs(f.spells) do n = n + 1 end
        for _ in pairs(f.rawIDs) do n = n + 1 end
        return n
    end

    -- Display name of the current selection (duplicate-prompt prefill)
    local function CurrentDisplayName()
        if selKind == "preset" then
            for _, cat in ipairs(R.Categories) do
                if cat.key == selKey then return L[cat.name] end
            end
            return selKey and tostring(selKey) or ""
        end
        local f = R:GetCustomFilter(selKey)
        return f and (f.name or tostring(selKey)) or ""
    end

    -- ========== INFO BANNER ==========
    local banner = GUI:CreateInfoBanner(parent, {
        tone = "info",
        text = L["Build and edit buff filters here, then enable them per row in Aura Filters. Changes you make to built-in presets are saved per profile and survive spell database updates."],
    })
    banner:SetPoint("TOPLEFT", 10, -10)
    banner:SetPoint("RIGHT", -10, 0)

    -- ========== LEFT COLUMN: FILTER LIST ==========
    local leftPanel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    leftPanel:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -12)
    leftPanel:SetSize(LEFT_W, PANEL_H)
    GUI:CreatePanelBackdrop(leftPanel, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    local leftScroll = CreateFrame("ScrollFrame", nil, leftPanel, "ScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 4, -4)
    leftScroll:SetPoint("BOTTOMRIGHT", -24, 60) -- bottom strip: 2 rows of action buttons
    DF.GUI.StyleScrollBar(leftScroll)

    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetSize(LEFT_W - 28, 1)
    leftScroll:SetScrollChild(leftContent)

    -- Section labels (created once, positioned during refresh)
    local function CreateSectionLabel(text)
        local fs = leftContent:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        return fs
    end
    local presetLabel = CreateSectionLabel(L["Built-in Presets"])
    local customLabel = CreateSectionLabel(L["Custom Filters"])

    -- ========== RIGHT COLUMN: HEADER + SEARCH + SPELL LIST ==========
    local rightArea = CreateFrame("Frame", nil, parent)
    rightArea:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 12, 0)
    rightArea:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    rightArea:SetHeight(PANEL_H)

    local titleText = rightArea:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    titleText:SetPoint("TOPLEFT", 0, -8)
    titleText:SetJustifyH("LEFT")

    local countText = rightArea:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    countText:SetPoint("LEFT", titleText, "RIGHT", 10, 0)
    countText:SetTextColor(0.5, 0.5, 0.5)

    -- Search box (placeholder-only; not db-backed)
    local searchBox = GUI:CreateEditBox(rightArea, "", nil, nil, nil, 170, L["Search..."])
    searchBox:SetPoint("TOPRIGHT", 0, 11)

    -- List background (top leaves room for the title row + add-by-ID row)
    local listBg = CreateFrame("Frame", nil, rightArea, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", 0, -64)
    listBg:SetPoint("BOTTOMRIGHT", 0, 0)
    GUI:CreatePanelBackdrop(listBg, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    local scrollFrame = CreateFrame("ScrollFrame", nil, listBg, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", -24, 4)
    DF.GUI.StyleScrollBar(scrollFrame)

    local scrollContent = CreateFrame("Frame", nil, scrollFrame)
    scrollContent:SetSize(400, 1)
    scrollFrame:SetScrollChild(scrollContent)
    -- The right column's width is anchor-driven; keep the row container synced
    scrollFrame:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then scrollContent:SetWidth(w) end
    end)

    local emptyText = listBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    emptyText:SetPoint("CENTER", listBg, "CENTER", 0, 0)

    -- ========== ADD-BY-ID ROW ==========
    -- Second header row between the title row and the spell list. Active for
    -- custom filters; greyed out while a preset is selected (presets are
    -- curated — the Add button's tooltip explains).
    -- CreateEditBox reserves 15px for its (empty) label, so the frame sits at
    -- -19 to land the editbox body at -34..-58; the list starts at -64.
    local addBox = GUI:CreateEditBox(rightArea, "", nil, nil, nil, 110, L["Spell ID"])
    addBox:SetPoint("TOPLEFT", 0, -19)

    -- Echo line: transient add-by-ID feedback, auto-hides after ~4s
    local echoText = rightArea:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    echoText:SetJustifyH("LEFT")
    echoText:SetWordWrap(false)
    echoText:SetTextColor(0.6, 0.6, 0.6)
    echoText:Hide()

    -- Generation counter so a re-add while a message is visible restarts the
    -- 4s window instead of the old timer hiding the new message early.
    local echoGen = 0
    local lastEchoSel
    local function HideEcho()
        echoGen = echoGen + 1
        echoText:Hide()
    end
    local function Echo(msg)
        echoGen = echoGen + 1
        local gen = echoGen
        echoText:SetText(msg)
        echoText:Show()
        C_Timer.After(4, function()
            if echoGen == gen then echoText:Hide() end
        end)
    end

    local function DoAddSpell()
        if selKind ~= "custom" or not R:GetCustomFilter(selKey) then return end
        local text = Trim(addBox.EditBox:GetText())
        if text == "" then return end
        -- Integers only: tonumber() also accepts floats/hex, which are never
        -- valid spell ids
        if not text:match("^%d+$") then
            Echo(L["Enter a valid spell ID."])
            return
        end
        local idNum = tonumber(text)
        local result = R:AddSpellToCustom(selKey, idNum)
        if result == "spell" then
            local rec = R.ByID[idNum]
            Echo(format(L["Added %s."], (R:GetSpellDisplay(rec))))
        elseif result == "raw" then
            Echo(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
        elseif result == "exists" then
            Echo(L["Already in this filter."])
            return
        else
            return
        end
        addBox.EditBox:SetText("")
        DirectFilterChangedProxy()
        RefreshAll()
    end

    local addBtn = GUI:CreateButton(rightArea, L["Add"], 50, 22, function(self)
        if self.dfDisabled then return end
        DoAddSpell()
    end)
    addBtn:SetPoint("LEFT", addBox.EditBox, "RIGHT", 6, 0)
    -- HookScript (not SetScript): StyleButton owns OnEnter for the hover wash
    addBtn:HookScript("OnEnter", function(self)
        if self.dfDisabled then
            GUI:ShowTooltip(self, { title = L["Presets are curated — add spells to a custom filter instead."] })
        end
    end)
    addBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

    -- Enter in the box adds too (the helper's own OnEnterPressed only saves
    -- db-backed values — this box has no db binding)
    addBox.EditBox:HookScript("OnEnterPressed", DoAddSpell)

    echoText:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
    -- Right edge pinned at the add-row's vertical center (-46 = editbox middle)
    echoText:SetPoint("RIGHT", rightArea, "TOPRIGHT", 0, -46)

    -- ========== RESET TO STOCK (preset header) ==========
    -- Only shown while the selected preset has per-profile overrides
    local resetBtn = GUI:CreateButton(rightArea, L["Reset to stock"], 110, 20, function()
        if selKind ~= "preset" or not selKey then return end
        R:ResetPreset(selKey)
        DirectFilterChangedProxy()
        RefreshAll()
    end)
    resetBtn:SetPoint("LEFT", countText, "RIGHT", 12, 0)
    resetBtn:Hide()

    -- ========== LEFT COLUMN ACTION BUTTONS ==========
    -- Created after the search box on purpose: SelectFilter clears the active
    -- search, so these handlers must close over the searchBox local.
    local LEFT_BTN_W = (LEFT_W - 12 - 4) / 2 -- two per row: 6px margins, 4px gap

    local function SelectFilter(kind, key)
        selKind, selKey = kind, key
        -- Clear the search when switching filters (SetText fires
        -- OnTextChanged, which syncs searchText and refreshes the list)
        if searchBox.EditBox:GetText() ~= "" then
            searchBox.EditBox:SetText("")
        end
        RefreshAll()
    end

    local newBtn = GUI:CreateButton(leftPanel, L["New Filter"], LEFT_BTN_W, 22, function()
        PromptFilterName(L["Name the new filter:"], "", function(text)
            text = Trim(text)
            if text == "" then return end
            SelectFilter("custom", R:CreateCustomFilter(text))
        end)
    end)
    newBtn:SetPoint("BOTTOMLEFT", 6, 32)

    local dupBtn = GUI:CreateButton(leftPanel, L["Duplicate"], LEFT_BTN_W, 22, function(self)
        if self.dfDisabled or not selKey then return end
        local src = selKey -- capture: selection may move before the prompt closes
        PromptFilterName(L["Name the duplicated filter:"], CurrentDisplayName() .. " copy", function(text)
            text = Trim(text)
            if text == "" then return end
            SelectFilter("custom", R:DuplicateFilter(src, text))
        end)
    end)
    dupBtn:SetPoint("BOTTOMRIGHT", -6, 32)

    local renameBtn = GUI:CreateButton(leftPanel, L["Rename"], LEFT_BTN_W, 22, function(self)
        if self.dfDisabled then return end
        local id = selKey
        local f = R:GetCustomFilter(id)
        if not f then return end
        PromptFilterName(L["Rename filter:"], f.name or "", function(text)
            text = Trim(text)
            if text == "" then return end
            R:RenameCustomFilter(id, text)
            RefreshAll()
        end)
    end)
    renameBtn:SetPoint("BOTTOMLEFT", 6, 6)

    local delBtn = GUI:CreateButton(leftPanel, L["Delete"], LEFT_BTN_W, 22, function(self)
        if self.dfDisabled then return end
        local id = selKey
        local f = R:GetCustomFilter(id)
        if not f then return end
        ConfirmDeleteFilter(f.name or tostring(id), function()
            R:DeleteCustomFilter(id)
            ScrubDeletedFilter(id)
            if selKind == "custom" and selKey == id then
                -- Move selection off the deleted filter (RefreshRight's guard
                -- would also catch this, but be explicit)
                selKind = "preset"
                selKey = R.Categories[1] and R.Categories[1].key
            end
            DirectFilterChangedProxy()
            RefreshAll()
        end)
    end)
    delBtn:SetPoint("BOTTOMRIGHT", -6, 6)

    -- ========== DATABASE FRESHNESS NOTE ==========
    -- Static by design: the stamp and the client build can't change
    -- mid-session, so the text is computed once at page build (no refresh
    -- wiring). Parented to leftPanel so it survives DoBuild's rebuild pass
    -- like the rest of the panel; it hangs just below the panel's frame.
    do
        local stamp = R.DBStamp
        if stamp then
            local freshText = format(L["Spell database: %s (build %d)"], stamp.harvest, stamp.gameBuild)
            local clientBuild = tonumber((select(2, GetBuildInfo())))
            if clientBuild and clientBuild > stamp.gameBuild then
                freshText = freshText .. "  |c" .. GUI:ToneHex("caution")
                    .. L["Spell database may be outdated."] .. "|r"
            end
            local freshLabel = GUI:CreateLabel(leftPanel, freshText, LEFT_W)
            freshLabel:SetPoint("TOPLEFT", leftPanel, "BOTTOMLEFT", 0, -2)
        end
    end

    -- Grey-when-disabled: SetDisabled keeps the button natively enabled so
    -- this tooltip can explain WHY (the OnClick handlers early-out instead)
    local function HookDisabledTooltip(btn, title)
        btn:HookScript("OnEnter", function(self)
            if self.dfDisabled then
                GUI:ShowTooltip(self, { title = title })
            end
        end)
        btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
    end
    HookDisabledTooltip(renameBtn, L["Built-in presets can't be renamed or deleted."])
    HookDisabledTooltip(delBtn, L["Built-in presets can't be renamed or deleted."])

    UpdateActionStates = function()
        local isCustom = selKind == "custom" and R:GetCustomFilter(selKey) ~= nil
        dupBtn:SetDisabled(selKey == nil)
        renameBtn:SetDisabled(not isCustom)
        delBtn:SetDisabled(not isCustom)
        addBox:SetEnabled(isCustom)
        addBtn:SetDisabled(not isCustom)
        resetBtn:SetShown((selKind == "preset" and selKey ~= nil and R:IsPresetModified(selKey)) or false)
    end

    -- ========== LEFT ROW POOL ==========
    local leftRows = {}
    local function AcquireLeftRow(i)
        local row = leftRows[i]
        if row then
            row:Show()
            return row
        end
        row = CreateFrame("Button", nil, leftContent, "BackdropTemplate")
        row:SetHeight(LEFT_ROW_H - 2)
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })

        -- Selection accent bar (theme-colored)
        row.accent = row:CreateTexture(nil, "ARTWORK")
        row.accent:SetSize(3, LEFT_ROW_H - 7)
        row.accent:SetPoint("LEFT", 2, 0)

        row.count = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        row.count:SetPoint("RIGHT", -8, 0)
        row.count:SetJustifyH("RIGHT")
        row.count:SetTextColor(0.5, 0.5, 0.5)

        -- Yellow "modified" dot (preset has per-profile overrides)
        row.dot = row:CreateTexture(nil, "OVERLAY")
        row.dot:SetSize(6, 6)
        row.dot:SetPoint("RIGHT", row.count, "LEFT", -5, 0)
        row.dot:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.dot:SetVertexColor(1, 0.82, 0, 1)

        row.name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        row.name:SetPoint("LEFT", 10, 0)
        row.name:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self)
            selKind, selKey = self._kind, self._key
            -- Clear the search when switching filters (SetText fires
            -- OnTextChanged, which syncs searchText and refreshes the list)
            if searchBox.EditBox:GetText() ~= "" then
                searchBox.EditBox:SetText("")
            end
            RefreshAll()
        end)
        row:SetScript("OnEnter", function(self)
            if not self._selected then
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
            end
        end)
        row:SetScript("OnLeave", function(self)
            if not self._selected then
                self:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
            end
        end)

        leftRows[i] = row
        return row
    end

    local function BindLeftRow(row, y, kind, key, nameStr, countStr, modified, selected)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row._kind, row._key, row._selected = kind, key, selected
        row.name:SetText(nameStr)
        row.count:SetText(countStr)
        row.dot:SetShown(modified)

        local tc = GUI.GetThemeColor()
        row.accent:SetColorTexture(tc.r, tc.g, tc.b, 1)
        row.accent:SetShown(selected)
        if selected then
            row:SetBackdropColor(tc.r * 0.30, tc.g * 0.30, tc.b * 0.30, 0.9)
            row.name:SetTextColor(0.95, 0.95, 0.95)
        else
            row:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
            row.name:SetTextColor(0.70, 0.70, 0.70)
        end
    end

    -- ========== SPELL LIST POOLS ==========
    -- Class header rows (plain fontstrings)
    local classHeaders = {}
    local function AcquireClassHeader(i)
        local fs = classHeaders[i]
        if fs then
            fs:Show()
            return fs
        end
        fs = scrollContent:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        fs:SetJustifyH("LEFT")
        classHeaders[i] = fs
        return fs
    end

    -- Spell rows
    local spellRows = {}
    local function AcquireSpellRow(i)
        local row = spellRows[i]
        if row then
            row:Show()
            return row
        end
        row = CreateFrame("Button", nil, scrollContent, "BackdropTemplate")
        row:SetHeight(SPELL_ROW_H - 2)
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        row:SetBackdropColor(0.08, 0.08, 0.08, 0.6)

        -- Spell icon
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 6, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        -- Preset view: Enable/Disable button (text rebound per state)
        row.action = GUI:CreateButton(row, L["Disable"], 64, 18, function()
            if row._onAction then row._onAction() end
        end)
        row.action:SetPoint("RIGHT", -6, 0)

        -- Custom view: inline destructive remove
        row.remove = GUI:CreateCloseButton(row, {
            size = 18,
            tone = "danger",
            onClick = function()
                if row._onRemove then row._onRemove() end
            end,
        })
        row.remove:SetPoint("RIGHT", -6, 0)

        -- Right-aligned chip: "+N" extra spellIDs, or the unknown-ID caption
        row.chip = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        row.chip:SetPoint("RIGHT", -76, 0)
        row.chip:SetJustifyH("RIGHT")
        row.chip:SetTextColor(0.5, 0.5, 0.5)

        -- Spell name
        row.name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.chip, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")

        -- Row click mirrors the action button in the preset view
        row:SetScript("OnClick", function(self)
            if self._rowToggles and self._onAction then self._onAction() end
        end)
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
            if self._spellID and not self._raw then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetSpellByID(self._spellID)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
            GUI:HideTooltip()
        end)

        spellRows[i] = row
        return row
    end

    local function BindSpellRow(row, y, item, isPreset)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)

        row.icon:SetTexture(item.icon or FALLBACK_ICON)
        row.name:SetText(item.name)
        row.chip:SetText(item.chip or "")
        -- Chip hugs the row's action control: 64px Enable/Disable button in
        -- the preset view, 18px remove "x" in the custom view
        row.chip:ClearAllPoints()
        row.chip:SetPoint("RIGHT", isPreset and -76 or -30, 0)
        row._spellID = item.tooltipID
        row._raw = item.raw
        row._rowToggles = isPreset

        local dim = isPreset and not item.enabled
        row.icon:SetAlpha(dim and 0.4 or 1)
        row.name:SetAlpha(dim and 0.4 or 1)
        if dim then
            row.name:SetTextColor(0.55, 0.55, 0.55)
        else
            row.name:SetTextColor(0.90, 0.90, 0.90)
        end

        if isPreset then
            row.action:Show()
            row.remove:Hide()
            row.action.Text:SetText(item.enabled and L["Disable"] or L["Enable"])
            local key, rec = selKey, item.rec
            row._onAction = function()
                R:SetSpellEnabled(key, rec, not R:IsSpellEnabled(key, rec))
                DirectFilterChangedProxy()
                RefreshAll()
            end
            row._onRemove = nil
        else
            row.action:Hide()
            row.remove:Show()
            local key, id = selKey, item.id
            row._onAction = nil
            row._onRemove = function()
                R:RemoveSpellFromCustom(key, id)
                DirectFilterChangedProxy()
                RefreshAll()
            end
        end
    end

    -- ========== REFRESH: LEFT LIST ==========
    RefreshLeft = function()
        local tc = GUI.GetThemeColor()
        presetLabel:SetTextColor(tc.r, tc.g, tc.b)
        customLabel:SetTextColor(tc.r, tc.g, tc.b)

        local y = 4
        presetLabel:ClearAllPoints()
        presetLabel:SetPoint("TOPLEFT", 6, -(y + 4))
        y = y + SECTION_H

        local used = 0
        for _, cat in ipairs(R.Categories) do
            used = used + 1
            local row = AcquireLeftRow(used)
            local enabled, total = R:PresetCounts(cat.key)
            BindLeftRow(row, y, "preset", cat.key, L[cat.name],
                enabled .. "/" .. total,
                R:IsPresetModified(cat.key),
                selKind == "preset" and selKey == cat.key)
            y = y + LEFT_ROW_H
        end

        y = y + 8
        customLabel:ClearAllPoints()
        customLabel:SetPoint("TOPLEFT", 6, -(y + 4))
        y = y + SECTION_H

        for _, cfId in ipairs(SortedCustomIDs()) do
            local f = R:GetCustomFilter(cfId)
            used = used + 1
            local row = AcquireLeftRow(used)
            BindLeftRow(row, y, "custom", cfId, f.name or cfId,
                tostring(CustomSpellCount(f)), false,
                selKind == "custom" and selKey == cfId)
            y = y + LEFT_ROW_H
        end

        -- Hide pooled rows beyond this refresh's needs
        for j = used + 1, #leftRows do
            leftRows[j]:Hide()
        end

        leftContent:SetHeight(mmax(1, y + 4))
    end

    -- ========== REFRESH: RIGHT LIST ==========
    RefreshRight = function()
        -- Guard: selected custom filter no longer exists (deleted elsewhere)
        if selKind == "custom" and not R:GetCustomFilter(selKey) then
            selKind = "preset"
            selKey = R.Categories[1] and R.Categories[1].key
        end
        local isPreset = selKind == "preset"

        -- Hide any lingering add-by-ID echo once the selection changes
        local selIdent = selKind .. "|" .. tostring(selKey)
        if selIdent ~= lastEchoSel then
            lastEchoSel = selIdent
            HideEcho()
        end

        local tc = GUI.GetThemeColor()
        titleText:SetTextColor(tc.r, tc.g, tc.b)

        -- Header: filter name + tracked/spell count
        if isPreset then
            local catName
            for _, cat in ipairs(R.Categories) do
                if cat.key == selKey then
                    catName = L[cat.name]
                    break
                end
            end
            titleText:SetText(catName or selKey or "")
            local enabled, total = R:PresetCounts(selKey)
            countText:SetText(format(L["%d of %d tracked"], enabled, total))
        else
            local f = R:GetCustomFilter(selKey)
            titleText:SetText(f and (f.name or selKey) or "")
            countText:SetText(format(L["%d spells"], f and CustomSpellCount(f) or 0))
        end

        -- Gather visible items grouped by class token
        local groups = {}
        local function put(token, item)
            token = token or "ALL"
            if not RAID_CLASS_COLORS or not RAID_CLASS_COLORS[token] then
                if token ~= "ALL" then token = "ALL" end
            end
            local g = groups[token]
            if not g then
                g = {}
                groups[token] = g
            end
            g[#g + 1] = item
        end
        local function matches(name)
            if searchText == "" then return true end
            return name:lower():find(searchText, 1, true) ~= nil
        end
        local function putRaw(id)
            local nm = format("#%d", id)
            if matches(nm) then
                put("ALL", {
                    id = id, name = nm, icon = FALLBACK_ICON,
                    chip = L["unknown ID"], raw = true, tooltipID = id,
                })
            end
        end

        if isPreset then
            for _, rec in ipairs(R.ByCategory[selKey] or {}) do
                local name, icon = R:GetSpellDisplay(rec)
                if matches(name) then
                    put(rec.class, {
                        rec = rec, id = rec.id, name = name, icon = icon,
                        chip = (rec.alts and #rec.alts > 0) and format("+%d", #rec.alts) or nil,
                        enabled = R:IsSpellEnabled(selKey, rec),
                        tooltipID = rec.id,
                    })
                end
            end
        else
            local f = R:GetCustomFilter(selKey)
            if f then
                for sid in pairs(f.spells) do
                    local rec = R.ByID[sid]
                    if rec then
                        local name, icon = R:GetSpellDisplay(rec)
                        if matches(name) then
                            put(rec.class, {
                                rec = rec, id = sid, name = name, icon = icon,
                                chip = (rec.alts and #rec.alts > 0) and format("+%d", #rec.alts) or nil,
                                tooltipID = rec.id,
                            })
                        end
                    else
                        -- Known id orphaned by a spell DB update: render as raw
                        putRaw(sid)
                    end
                end
                for rid in pairs(f.rawIDs) do
                    putRaw(rid)
                end
            end
        end

        -- Sort within each group: named spells alphabetically, raw ids last
        for _, g in pairs(groups) do
            tsort(g, function(a, b)
                if (a.raw or false) ~= (b.raw or false) then return not a.raw end
                if a.raw then return a.id < b.id end
                if a.name ~= b.name then return a.name < b.name end
                return a.id < b.id
            end)
        end

        -- Render groups in class order, ALL last
        local y = 4
        local usedHeaders, usedRows, shown = 0, 0, 0
        local function RenderGroup(token)
            local g = groups[token]
            if not g or #g == 0 then return end
            usedHeaders = usedHeaders + 1
            local hdr = AcquireClassHeader(usedHeaders)
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", 6, -(y + 6))
            hdr:SetText(ClassDisplayName(token))
            local cc = token ~= "ALL" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
            if cc then
                hdr:SetTextColor(cc.r, cc.g, cc.b)
            else
                hdr:SetTextColor(0.65, 0.65, 0.65)
            end
            y = y + CLASS_HEADER_H

            for _, item in ipairs(g) do
                usedRows = usedRows + 1
                shown = shown + 1
                local row = AcquireSpellRow(usedRows)
                BindSpellRow(row, y, item, isPreset)
                y = y + SPELL_ROW_H
            end
            y = y + 4
        end
        for _, token in ipairs(CLASS_ORDER) do
            RenderGroup(token)
        end
        RenderGroup("ALL")

        -- Hide pooled widgets beyond this refresh's needs
        for j = usedHeaders + 1, #classHeaders do
            classHeaders[j]:Hide()
        end
        for j = usedRows + 1, #spellRows do
            spellRows[j]:Hide()
        end

        emptyText:SetShown(shown == 0)
        emptyText:SetText(searchText ~= "" and L["No results found"] or L["This filter is empty."])

        scrollContent:SetHeight(mmax(1, y + 4))
    end

    RefreshAll = function()
        RefreshLeft()
        RefreshRight()
        UpdateActionStates()
    end
    pageRef._fdRefreshAll = RefreshAll

    -- ========== SEARCH WIRING ==========
    -- HookScript (not SetScript): CreateEditBox already hooks OnTextChanged
    -- for its placeholder handling.
    searchBox.EditBox:HookScript("OnTextChanged", function(eb)
        local q = (eb:GetText() or ""):lower()
        if q == searchText then return end
        searchText = q
        RefreshRight()
    end)

    -- ========== THEME LISTENER ==========
    -- Recolor selection highlights, section labels, and the title on theme change
    local themeListener = { UpdateTheme = function() RefreshAll() end }
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    tinsert(parent.ThemeListeners, themeListener)
    pageRef._fdThemeListener = themeListener

    -- ========== PAGE HEIGHT SPACER ==========
    -- The page's scroll height comes from RefreshStates summing Add()ed
    -- children; this page anchors its frames directly, so an invisible spacer
    -- carries the total height through the standard layout pass.
    local spacer = CreateFrame("Frame", nil, parent)
    spacer:SetSize(1, 1)
    spacer.layoutCol = "both"
    local bannerH = (banner:GetHeight() > 0) and banner:GetHeight() or (banner.layoutHeight or 34)
    -- +24: the database-freshness label hangs below the left panel
    spacer.layoutHeight = 22 + bannerH + PANEL_H + 24 + 20
    pageRef._fdSpacer = spacer
    if pageRef.children then
        tinsert(pageRef.children, spacer)
    end

    RefreshAll()
end
