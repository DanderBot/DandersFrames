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

-- The async load-on-demand spell tooltip (R.ShowSpellTooltip), the fixed
-- class grouping order (R.PickerClassOrder), the localized class names
-- (R.ClassDisplayName) and the class-coloured name styling
-- (R.ApplyClassNameColor) live in FilterRegistry/SpellPicker.lua — shared
-- with the spell database picker. That file loads AFTER this one, so bind
-- them at build time (inside BuildFilterDesignerPage), never at file scope.

-- Spell-list "still showing this spell?" predicate for the async tooltip
-- (file-local so the pooled OnEnter handlers don't allocate a closure per
-- hover)
local function SpellRowStillShows(row, spellID)
    return row._spellID == spellID and not row._raw
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
        if type(cfg) == "table" then
            scrubLayoutGroups(cfg.layoutGroups)
            -- Other Buffs layout groups: a flat array only (new store, never
            -- spec-keyed — no dual-shape dispatch needed).
            if type(cfg.otherLayoutGroups) == "table" then
                scrubGroupArray(cfg.otherLayoutGroups)
            end
        end
    end
    -- Raid auto-layout overrides: a layout-edit session stores a whole-table
    -- copy of the mode selection tables — INCLUDING .customs — into each
    -- layout's overrides (AutoProfiles' ExitEditing diff scan), and
    -- ApplyRuntimeProfile re-injects that copy on every activation. Without
    -- this walk the deleted id resurrects with the layout, and a dangling
    -- customs key makes ResolveSelection return an empty include map (the
    -- row renders NOTHING while that layout is active).
    local function scrubSelection(sel)
        if type(sel) == "table" and type(sel.customs) == "table" then
            sel.customs[cfId] = nil
        end
    end
    local function scrubAutoLayouts(autoDb)
        if type(autoDb) ~= "table" then return end
        local function scrubLayout(layout)
            local ov = type(layout) == "table" and layout.overrides
            if type(ov) == "table" then
                scrubSelection(ov.buffFilterSelection)
                scrubSelection(ov.defensiveFilterSelection)
            end
        end
        for _, ct in pairs(autoDb) do
            if type(ct) == "table" then
                if type(ct.profiles) == "table" then
                    for _, layout in pairs(ct.profiles) do scrubLayout(layout) end
                end
                scrubLayout(ct.profile)   -- mythic carries a single layout
            end
        end
    end

    for _, profile in pairs(profiles) do
        if type(profile) == "table" then
            for i = 1, 2 do
                local mode = (i == 1) and profile.party or profile.raid
                if type(mode) == "table" then
                    scrubSelection(mode.buffFilterSelection)
                    scrubSelection(mode.defensiveFilterSelection)
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
            scrubAutoLayouts(profile.raidAutoProfiles)
        end
    end

    -- Live runtime overlay: while an auto layout is ACTIVE its override copy
    -- is what the raid proxy actually reads (until the next re-apply) — clear
    -- the id there too so it can't drive the current session's rows.
    local live = DF.raidOverrides
    if type(live) == "table" then
        scrubSelection(live.buffFilterSelection)
        scrubSelection(live.defensiveFilterSelection)
    end
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

    -- Shared helpers from FilterRegistry/SpellPicker.lua (loads after this
    -- file — safe here because pages build long after load time)
    local CLASS_ORDER = R.PickerClassOrder
    local ClassDisplayName = R.ClassDisplayName
    local ApplyNameColor = R.ApplyClassNameColor
    local ShowSpellTooltip = R.ShowSpellTooltip

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

    -- ========== RESET TO DEFAULT (header row 1) ==========
    -- Red danger tone (icon + label), matching the Reset Page button. Only
    -- shown while the selected preset has per-profile overrides. Flows after
    -- the counts, so it can't collide with the search box at narrow GUI widths
    -- (search lives on its own row below).
    local resetBtn = CreateFrame("Button", nil, headerPanel, "BackdropTemplate")
    resetBtn:SetSize(115, 20)
    GUI:StyleButton(resetBtn, {
        tone = "danger",
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh", size = 14 },
        text = L["Reset to Default"],
    })
    resetBtn:SetWidth(math.ceil(resetBtn.Text:GetStringWidth()) + 32)
    resetBtn:SetPoint("LEFT", countText, "RIGHT", 12, 0)
    resetBtn:Hide()
    resetBtn:SetScript("OnClick", function()
        if selKind ~= "preset" or not selKey then return end
        R:ResetPreset(selKey)
        DirectFilterChangedProxy()
        RefreshAll()
    end)

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
        -- Length cap after zero-strip (same rule as the shared picker):
        -- past ~15 digits tonumber loses integer precision, and the float
        -- would persist as a junk key in the account-wide store.
        text = text:match("^0*(%d+)$") or text
        if #text > 10 then
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
            GUI:ShowTooltip(self, { title = L["Presets are curated"], lines = { L["You can enable or disable the spells shown, but not add new ones. Create a custom filter to add your own."] } })
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
    local function HookDisabledTooltip(btn, title, desc)
        btn:HookScript("OnEnter", function(self)
            if self.dfDisabled then
                GUI:ShowTooltip(self, { title = title, lines = desc and { desc } or nil })
            end
        end)
        btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
    end
    HookDisabledTooltip(renameBtn, L["Presets are curated"], L["Built-in presets can't be renamed or deleted."])
    HookDisabledTooltip(delBtn, L["Presets are curated"], L["Built-in presets can't be renamed or deleted."])
    HookDisabledTooltip(dbBtn, L["Presets are curated"], L["You can enable or disable the spells shown, but not add new ones. Create a custom filter to add your own."])

    -- ========== ADD-FROM-DATABASE PICKER ==========
    -- The shared spell database picker (FilterRegistry/SpellPicker.lua):
    -- in-page overlay covering both columns (the spell DB is far too large
    -- for a StaticPopup), search box + class/category filters + pooled list
    -- of every DB spell, class-grouped like the main spell list. Clicking a
    -- row adds the spell to the target custom filter; rows already in the
    -- filter render dimmed with a check instead of being clickable. Esc or
    -- the close button dismisses; search + filters reset on every open.
    local pickerTarget -- custom filter id the picker adds into
    local pickerHandle -- shared-picker handle (nil until the first open)

    OpenPicker = function(cfId)
        pickerTarget = cfId
        pickerHandle = R:OpenSpellPicker({
            parent = parent,
            points = {
                { "TOPLEFT", leftPanel, "TOPLEFT", 0, 0 },
                { "BOTTOMRIGHT", rightArea, "BOTTOMRIGHT", 0, 0 },
            },
            title = L["Add from Database"],
            -- Re-evaluated per refresh, so a rename while the picker is up
            -- keeps the header current
            subtitle = function()
                local f = R:GetCustomFilter(pickerTarget)
                return f and (f.name or tostring(pickerTarget)) or ""
            end,
            -- Target filter deleted while open -> the picker closes itself
            isValid = function()
                return R:GetCustomFilter(pickerTarget) ~= nil
            end,
            -- "Already in this filter" renders as the dimmed check row
            isBlocked = function(rec)
                local f = R:GetCustomFilter(pickerTarget)
                return (f and f.spells[rec.id] ~= nil) and true or nil
            end,
            rowActions = {
                {
                    handler = function(rec)
                        if R:AddSpellToCustom(pickerTarget, rec.id) then
                            DirectFilterChangedProxy()
                            RefreshAll() -- re-renders the picker too, so the row shows its check
                        end
                    end,
                },
            },
        })
    end

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

        -- "Modified" override marker (preset has per-profile enable/disable
        -- overrides). Shared filled-dot marker used for overrides addon-wide;
        -- it propagates clicks so it doesn't swallow the row's select handler.
        row.dot = GUI:CreateOverrideMarker(row, 8)
        row.dot:SetPoint("RIGHT", row.count, "LEFT", -3, 0)
        row.dot.tooltipText = L["Override active"]
        row.dot.tooltipSubText = L["This preset has been changed from its defaults."]

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
                ShowSpellTooltip(self, self._spellID, self._infoTitle, SpellRowStillShows)
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
        row.icon:SetDesaturated(dim)
        row.name:SetAlpha(dim and 0.5 or 1)
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
    local rawResolveRepaint -- one pending repaint while direct-ID spell data streams in
    local rawResolveTried = {} -- ids already given their one load-request + repaint
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
            -- Not in the shipped database: resolve name/icon LIVE from the
            -- client so a valid direct ID reads like a real spell — the row
            -- keeps a "not in database" chip to mark it. The first resolve can
            -- miss while spell data streams in, so request the load and repaint
            -- once shortly after; only a genuinely unknown ID keeps the
            -- "#id" + question-mark presentation.
            local name, icon
            if C_Spell and C_Spell.GetSpellName then
                local ok, v = pcall(C_Spell.GetSpellName, id)
                if ok and type(v) == "string" and v ~= "" then name = v end
                local okT, t = pcall(C_Spell.GetSpellTexture, id)
                if okT and type(t) == "number" then icon = t end
                if not name and C_Spell.RequestLoadSpellData and not rawResolveTried[id] then
                    -- One load-request + one repaint per id, ever: a genuinely
                    -- invalid id never resolves, and re-requesting from the
                    -- repaint's own RefreshRight would loop the 0.8s timer
                    -- forever (even with the page closed).
                    rawResolveTried[id] = true
                    pcall(C_Spell.RequestLoadSpellData, id)
                    if not rawResolveRepaint then
                        rawResolveRepaint = true
                        C_Timer.After(0.8, function()
                            rawResolveRepaint = nil
                            RefreshRight()
                        end)
                    end
                end
            end
            local nm = name or format("#%d", id)
            if matches(nm) then
                put("ALL", {
                    id = id, name = nm, icon = icon or FALLBACK_ICON,
                    chip = name and L["not in database"] or L["unknown ID"],
                    raw = true, tooltipID = id,
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
                -- Raw rows sort by resolved name too; unresolved "#id" names
                -- cluster first ("#" < letters), ordered by id via the tiebreak.
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
        if pickerHandle and pickerHandle:IsOpen() then
            if selKind == "custom" and selKey == pickerTarget and R:GetCustomFilter(pickerTarget) then
                pickerHandle:Refresh()
            else
                pickerHandle:Close()
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
