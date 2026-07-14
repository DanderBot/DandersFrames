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
-- per-mode selections (both the buff and defensive rows) AND from every
-- Aura Designer filter group's filterSelection (A5 — the AD preset
-- libraries plus legacy inline auraDesigner tables), or stale ids linger
-- in SavedVariables forever. Nil-safe against profiles that predate the
-- selection tables, are missing a mode entirely, or carry the pre-V2
-- flat (non-spec-keyed) layoutGroups shape.
local function ScrubDeletedFilter(cfId)
    local sv = DandersFramesDB_v2
    local profiles = sv and sv.profiles
    if type(profiles) ~= "table" then return end

    -- One array of layout-group records: nil the deleted id from every
    -- filter group's customs selection. Member groups carry no selection.
    local function scrubGroupArray(groups)
        for _, g in ipairs(groups) do
            if type(g) == "table" then
                local sel = g.filterSelection
                if type(sel) == "table" and type(sel.customs) == "table" then
                    sel.customs[cfId] = nil
                end
            end
        end
    end
    -- layoutGroups is spec-keyed post-V2 ({ [specKey] = {groups} }) but may
    -- still be the legacy flat array on unmigrated configs — walk both shapes.
    local function scrubLayoutGroups(lg)
        if type(lg) ~= "table" then return end
        if lg[1] ~= nil then scrubGroupArray(lg) end
        for k, v in pairs(lg) do
            if type(k) == "string" and type(v) == "table" then
                scrubGroupArray(v)
            end
        end
    end
    local function scrubADConfig(cfg)
        if type(cfg) == "table" then scrubLayoutGroups(cfg.layoutGroups) end
    end

    for _, profile in pairs(profiles) do
        if type(profile) == "table" then
            for i = 1, 2 do
                local mode = (i == 1) and profile.party or profile.raid
                if type(mode) == "table" then
                    local sel = mode.buffFilterSelection
                    if sel and sel.customs then sel.customs[cfId] = nil end
                    sel = mode.defensiveFilterSelection
                    if sel and sel.customs then sel.customs[cfId] = nil end
                    -- Legacy inline AD config (pre-preset-library profiles)
                    scrubADConfig(mode.auraDesigner)
                end
            end
            -- AD preset library (post-migration home of every AD config)
            if type(profile.auraDesignerPresets) == "table" then
                for _, preset in pairs(profile.auraDesignerPresets) do
                    scrubADConfig(preset)
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
    local HEADER_H = 92 -- right-column header panel (3 stacked rows)

    -- ========== STATE ==========
    local selKind = "preset" -- "preset" | "custom"
    local selKey = R.Categories[1] and R.Categories[1].key
    local searchText = "" -- lowercased query

    local RefreshLeft, RefreshRight, RefreshAll, UpdateActionStates, OpenPicker -- forward declarations

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

    -- Class-coloured spell name. Disabled/already-added rows keep their 40%
    -- alpha dim ON TOP of the class colour — the colour is scaled (0.61 ≈ the
    -- 0.55/0.90 ratio of the neutral dim), never dropped. Records without a
    -- valid class token ("ALL", raw ids) keep the neutral colours.
    local function ApplyNameColor(fs, classToken, dim)
        local cc = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
        if cc then
            local m = dim and 0.61 or 1
            fs:SetTextColor(cc.r * m, cc.g * m, cc.b * m)
        elseif dim then
            fs:SetTextColor(0.55, 0.55, 0.55)
        else
            fs:SetTextColor(0.90, 0.90, 0.90)
        end
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

    -- ========== RIGHT COLUMN: HEADER PANEL + SPELL LIST ==========
    local rightArea = CreateFrame("Frame", nil, parent)
    rightArea:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 12, 0)
    rightArea:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    rightArea:SetHeight(PANEL_H)

    -- Header container: title/counts/reset (row 1), search (row 2) and
    -- add-by-ID (row 3) share one backdrop panel whose TOP aligns with the
    -- left panel's TOP, so both columns start at the same height. Each row
    -- flows in a single direction, so no header control can overlap another
    -- at any GUI width.
    local headerPanel = CreateFrame("Frame", nil, rightArea, "BackdropTemplate")
    headerPanel:SetPoint("TOPLEFT", 0, 0)
    headerPanel:SetPoint("TOPRIGHT", 0, 0)
    headerPanel:SetHeight(HEADER_H)
    GUI:CreatePanelBackdrop(headerPanel, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    -- Row 1: title + counts + reset, flowing left-to-right only.
    local titleText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    titleText:SetPoint("TOPLEFT", 10, -10)
    titleText:SetJustifyH("LEFT")

    local countText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    countText:SetPoint("LEFT", titleText, "RIGHT", 10, 0)
    countText:SetTextColor(0.5, 0.5, 0.5)

    -- ========== RESET TO STOCK (header row 1) ==========
    -- Only shown while the selected preset has per-profile overrides. Flows
    -- after the counts, so it can no longer collide with the search box at
    -- narrow GUI widths (search lives on its own row below).
    local resetBtn = GUI:CreateButton(headerPanel, L["Reset to stock"], 110, 20, function()
        if selKind ~= "preset" or not selKey then return end
        R:ResetPreset(selKey)
        DirectFilterChangedProxy()
        RefreshAll()
    end)
    resetBtn:SetPoint("LEFT", countText, "RIGHT", 12, 0)
    resetBtn:Hide()

    -- Row 2: the Add-from-Database picker button is right-anchored; the
    -- search box stretches between the panel's left edge and the button, so
    -- it shrinks instead of overlapping. Active for custom filters; greyed
    -- out while a preset is selected (same tooltip pattern as add-by-ID).
    local dbBtn = GUI:CreateButton(headerPanel, L["Add from Database"], 130, 22, function(self)
        if self.dfDisabled then return end
        if selKind ~= "custom" or not R:GetCustomFilter(selKey) then return end
        OpenPicker(selKey)
    end)
    dbBtn:SetPoint("TOPRIGHT", -10, -30)

    -- Search box (placeholder-only; not db-backed). CreateEditBox reserves
    -- 15px for its (empty) label, so the frame sits at -15 to land the
    -- editbox body at -30..-54, level with the picker button.
    local searchBox = GUI:CreateEditBox(headerPanel, "", nil, nil, nil, 170, L["Search..."])
    searchBox:SetPoint("TOPLEFT", 10, -15)
    searchBox:SetPoint("TOPRIGHT", dbBtn, "TOPLEFT", -8, 15)

    -- List background sits below the header panel
    local listBg = CreateFrame("Frame", nil, rightArea, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", headerPanel, "BOTTOMLEFT", 0, -8)
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

    -- ========== ADD-BY-ID ROW (header row 3) ==========
    -- Active for custom filters; greyed out while a preset is selected
    -- (presets are curated — the Add button's tooltip explains).
    -- Frame at -43 lands the editbox body at -58..-82.
    local addBox = GUI:CreateEditBox(headerPanel, "", nil, nil, nil, 90, L["Spell ID"])
    addBox:SetPoint("TOPLEFT", 10, -43)

    -- Echo line: transient add-by-ID feedback, auto-hides after ~4s
    local echoText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
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

    local addBtn = GUI:CreateButton(headerPanel, L["Add"], 50, 22, function(self)
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
    -- Right edge pinned at the add-row's vertical center (-70 = editbox middle)
    echoText:SetPoint("RIGHT", headerPanel, "TOPRIGHT", -10, -70)

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
    -- Expose for cross-page affordances: the Aura Designer's "Create Filter"
    -- button navigates here and pulses this button (DF:HighlightWidget).
    pageRef._fdNewFilterBtn = newBtn

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
    HookDisabledTooltip(dbBtn, L["Presets are curated — add spells to a custom filter instead."])

    -- ========== ADD-FROM-DATABASE PICKER ==========
    -- In-page overlay covering both columns (the spell DB is far too large
    -- for a StaticPopup): its own search box + pooled list of every DB spell,
    -- class-grouped like the main spell list (name-sorted within each group,
    -- "ALL" last). Clicking a row adds the spell to the target custom
    -- filter; rows already in the filter render dimmed with a check instead
    -- of being clickable. Esc or the close button dismisses.
    local picker = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    picker:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, 0)
    picker:SetPoint("BOTTOMRIGHT", rightArea, "BOTTOMRIGHT", 0, 0)
    picker:SetFrameLevel(parent:GetFrameLevel() + 30)
    GUI:CreatePanelBackdrop(picker, { bgAlpha = 0.98, borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })
    picker:EnableMouse(true) -- swallow clicks aimed at the page underneath
    picker:Hide()

    local pickerTarget -- custom filter id the picker adds into
    local pickerSearch = "" -- lowercased query
    local RefreshPicker

    -- Close on Escape (same idiom as the Aura Designer popups)
    picker:EnableKeyboard(true)
    picker:SetPropagateKeyboardInput(true)
    picker:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    local pickerTitle = picker:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    pickerTitle:SetPoint("TOPLEFT", 10, -11)
    pickerTitle:SetText(L["Add from Database"])

    local pickerTargetText = picker:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    pickerTargetText:SetPoint("LEFT", pickerTitle, "RIGHT", 10, 0)
    pickerTargetText:SetTextColor(0.5, 0.5, 0.5)

    local pickerClose = GUI:CreateCloseButton(picker, {
        size = 20,
        onClick = function() picker:Hide() end,
    })
    pickerClose:SetPoint("TOPRIGHT", -8, -8)

    -- Search box, stretched to clear the close button (body at -33..-57)
    local pickerSearchBox = GUI:CreateEditBox(picker, "", nil, nil, nil, 170, L["Search..."])
    pickerSearchBox:SetPoint("TOPLEFT", 10, -18)
    pickerSearchBox:SetPoint("TOPRIGHT", -36, -18)

    local pickerListBg = CreateFrame("Frame", nil, picker, "BackdropTemplate")
    pickerListBg:SetPoint("TOPLEFT", 10, -64)
    pickerListBg:SetPoint("BOTTOMRIGHT", -10, 10)
    GUI:CreatePanelBackdrop(pickerListBg, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    local pickerScroll = CreateFrame("ScrollFrame", nil, pickerListBg, "ScrollFrameTemplate")
    pickerScroll:SetPoint("TOPLEFT", 4, -4)
    pickerScroll:SetPoint("BOTTOMRIGHT", -24, 4)
    DF.GUI.StyleScrollBar(pickerScroll)

    local pickerContent = CreateFrame("Frame", nil, pickerScroll)
    pickerContent:SetSize(400, 1)
    pickerScroll:SetScrollChild(pickerContent)
    pickerScroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then pickerContent:SetWidth(w) end
    end)

    local pickerEmpty = pickerListBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    pickerEmpty:SetPoint("CENTER", pickerListBg, "CENTER", 0, 0)
    pickerEmpty:SetText(L["No results found"])
    pickerEmpty:Hide()

    -- Class-grouped index over the whole DB, built once on first open
    -- (names cached for the sort + search; icons fetched fresh at bind).
    -- Keyed by class token; records without a valid class token collapse
    -- into "ALL", same as the main list. Name-sorted within each group.
    local pickerIndex
    local function GetPickerIndex()
        if not pickerIndex then
            pickerIndex = {}
            for _, rec in ipairs(R.Spells) do
                local token = rec.class or "ALL"
                if token ~= "ALL" and not (RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]) then
                    token = "ALL"
                end
                local g = pickerIndex[token]
                if not g then
                    g = {}
                    pickerIndex[token] = g
                end
                local name = R:GetSpellDisplay(rec)
                g[#g + 1] = { rec = rec, name = name, lower = name:lower() }
            end
            for _, g in pairs(pickerIndex) do
                tsort(g, function(a, b)
                    if a.name ~= b.name then return a.name < b.name end
                    return a.rec.id < b.rec.id
                end)
            end
        end
        return pickerIndex
    end

    -- Picker class-header pool (same pooled-fontstring idiom as the main
    -- spell list's class headers)
    local pickerHeaders = {}
    local function AcquirePickerHeader(i)
        local fs = pickerHeaders[i]
        if fs then
            fs:Show()
            return fs
        end
        fs = pickerContent:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        fs:SetJustifyH("LEFT")
        pickerHeaders[i] = fs
        return fs
    end

    -- Picker row pool (same pooled-row idiom as the main spell list)
    local pickerRows = {}
    local function AcquirePickerRow(i)
        local row = pickerRows[i]
        if row then
            row:Show()
            return row
        end
        row = CreateFrame("Button", nil, pickerContent, "BackdropTemplate")
        row:SetHeight(SPELL_ROW_H - 2)
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        row:SetBackdropColor(0.08, 0.08, 0.08, 0.6)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 6, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        -- "Already added" affordance: green check instead of clickability
        row.check = row:CreateTexture(nil, "OVERLAY")
        row.check:SetSize(14, 14)
        row.check:SetPoint("RIGHT", -8, 0)
        row.check:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
        row.check:SetVertexColor(0.4, 0.85, 0.5)

        row.name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.check, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self)
            if self._added or not self._rec then return end
            if R:AddSpellToCustom(pickerTarget, self._rec.id) then
                DirectFilterChangedProxy()
                RefreshAll() -- rebinds this list too, so the row shows its check
            end
        end)
        row:SetScript("OnEnter", function(self)
            if not self._added then
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
            end
            if self._rec then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetSpellByID(self._rec.id)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
            GUI:HideTooltip()
        end)

        pickerRows[i] = row
        return row
    end

    local function BindPickerRow(row, y, entry, added)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        local rec = entry.rec
        local _, icon = R:GetSpellDisplay(rec)
        row.icon:SetTexture(icon or FALLBACK_ICON)
        row.name:SetText(entry.name)
        row._rec, row._added = rec, added

        row.check:SetShown(added)
        row.icon:SetAlpha(added and 0.4 or 1)
        row.name:SetAlpha(added and 0.4 or 1)
        ApplyNameColor(row.name, rec.class, added)
        row:SetBackdropColor(0.08, 0.08, 0.08, 0.6) -- clear any lingering hover
    end

    RefreshPicker = function()
        local f = R:GetCustomFilter(pickerTarget)
        if not f then
            picker:Hide()
            return
        end
        pickerTargetText:SetText(f.name or tostring(pickerTarget))
        local tc = GUI.GetThemeColor()
        pickerTitle:SetTextColor(tc.r, tc.g, tc.b)

        -- Render groups in class order, ALL last. Headers are placed lazily
        -- on a group's first matching row, so a group with zero search
        -- matches never shows its header.
        local index = GetPickerIndex()
        local y = 4
        local usedHeaders, usedRows = 0, 0
        local function RenderGroup(token)
            local g = index[token]
            if not g then return end
            local headerPlaced = false
            for _, entry in ipairs(g) do
                if pickerSearch == "" or entry.lower:find(pickerSearch, 1, true) then
                    if not headerPlaced then
                        headerPlaced = true
                        usedHeaders = usedHeaders + 1
                        local hdr = AcquirePickerHeader(usedHeaders)
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
                    end
                    usedRows = usedRows + 1
                    local row = AcquirePickerRow(usedRows)
                    BindPickerRow(row, y, entry, f.spells[entry.rec.id] ~= nil)
                    y = y + SPELL_ROW_H
                end
            end
            if headerPlaced then y = y + 4 end
        end
        for _, token in ipairs(CLASS_ORDER) do
            RenderGroup(token)
        end
        RenderGroup("ALL")

        -- Hide pooled widgets beyond this refresh's needs
        for j = usedHeaders + 1, #pickerHeaders do
            pickerHeaders[j]:Hide()
        end
        for j = usedRows + 1, #pickerRows do
            pickerRows[j]:Hide()
        end
        pickerEmpty:SetShown(usedRows == 0)
        pickerContent:SetHeight(mmax(1, y + 4))
    end

    OpenPicker = function(cfId)
        pickerTarget = cfId
        -- Clear the search (SetText fires OnTextChanged, which syncs
        -- pickerSearch; the refresh below renders the full list)
        if pickerSearchBox.EditBox:GetText() ~= "" then
            pickerSearchBox.EditBox:SetText("")
        end
        picker:Show()
        RefreshPicker()
    end

    -- HookScript (not SetScript): CreateEditBox already hooks OnTextChanged
    -- for its placeholder handling.
    pickerSearchBox.EditBox:HookScript("OnTextChanged", function(eb)
        local q = (eb:GetText() or ""):lower()
        if q == pickerSearch then return end
        pickerSearch = q
        if picker:IsShown() then RefreshPicker() end
    end)

    UpdateActionStates = function()
        local isCustom = selKind == "custom" and R:GetCustomFilter(selKey) ~= nil
        dupBtn:SetDisabled(selKey == nil)
        renameBtn:SetDisabled(not isCustom)
        delBtn:SetDisabled(not isCustom)
        addBox:SetEnabled(isCustom)
        addBtn:SetDisabled(not isCustom)
        dbBtn:SetDisabled(not isCustom)
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

        -- 'i' info button: hovering lists the spell's canonical + variant IDs.
        -- Same Media\Icons "info" asset the info banners use (via CreateButton's
        -- iconName param); repositioned per bind next to the row's action.
        row.info = GUI:CreateButton(row, nil, 18, 18, nil, "info")
        row.info.Icon:SetVertexColor(0.6, 0.6, 0.6)
        row.info:HookScript("OnEnter", function(self)
            if row._infoTitle then
                GUI:ShowTooltip(self, {
                    title = row._infoTitle,
                    lines = { format(L["Spell IDs: %s"], row._infoIDs or "") },
                })
            end
        end)
        row.info:HookScript("OnLeave", function() GUI:HideTooltip() end)

        -- Right-aligned chip: "+N" extra spellIDs, or the unknown-ID caption.
        -- Anchored to the info button, so it follows per-bind repositioning.
        row.chip = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        row.chip:SetPoint("RIGHT", row.info, "LEFT", -6, 0)
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
        -- Info button hugs the row's action control: 64px Enable/Disable
        -- button in the preset view, 18px remove "x" in the custom view.
        -- The chip is anchored to the info button, so it follows.
        row.info:ClearAllPoints()
        row.info:SetPoint("RIGHT", isPreset and -74 or -28, 0)
        row._spellID = item.tooltipID
        row._raw = item.raw
        row._rowToggles = isPreset

        -- Info tooltip data: canonical + variant IDs for known spells, just
        -- the raw ID otherwise. Rebuilt on every bind like the rest.
        row._infoTitle = item.name
        local rec = item.rec
        if rec and rec.alts and #rec.alts > 0 then
            row._infoIDs = rec.id .. ", " .. table.concat(rec.alts, ", ")
        else
            row._infoIDs = tostring(rec and rec.id or item.id)
        end

        local dim = isPreset and not item.enabled
        row.icon:SetAlpha(dim and 0.4 or 1)
        row.name:SetAlpha(dim and 0.4 or 1)
        ApplyNameColor(row.name, rec and rec.class, dim)

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
        -- Keep the picker coherent: hide it when the selection moved off its
        -- target custom filter (or the filter was deleted); otherwise
        -- re-render so newly-added rows pick up their check/dim state.
        if picker:IsShown() then
            if selKind == "custom" and selKey == pickerTarget and R:GetCustomFilter(pickerTarget) then
                RefreshPicker()
            else
                picker:Hide()
            end
        end
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
