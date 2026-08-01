-- Part 5 of the Aura Designer editor, split from Options.lua.
-- Aliases of objects the first part created; they add no state.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local L = DF.L
local GUI = DF.GUI
local Adapter = DF.AuraDesigner.Adapter
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv
local C_BACKGROUND = GUI.Colors.background
local C_ELEMENT = GUI.Colors.element
local C_BORDER = GUI.Colors.border
local C_HOVER = GUI.Colors.hover
local C_TEXT = GUI.Colors.text
local C_TEXT_DIM = GUI.Colors.textDim
local OPTS = P.OPTS
local GetAuraDesignerDB = P.GetAuraDesignerDB
local GetThemeColor = P.GetThemeColor
local ApplyBackdrop = P.ApplyBackdrop
local CreateCardShell = P.CreateCardShell
local ResolveSpec = P.ResolveSpec
local CreateDebuffGroup = P.CreateDebuffGroup
local IsOtherTab = P.IsOtherTab
local CurrentAuraPool = P.CurrentAuraPool
local PoolKeyPrefix = P.PoolKeyPrefix
local DebuffGroupsRead = P.DebuffGroupsRead
local CurrentLayoutGroups = P.CurrentLayoutGroups
local OtherPoolDisplayName = P.OtherPoolDisplayName
local RemoveIndicatorInstance = P.RemoveIndicatorInstance
local GetAuraIcon = P.GetAuraIcon
local expandedGroups = P.expandedGroups
local GroupExpandKey = P.GroupExpandKey
local CreateLayoutGroup = P.CreateLayoutGroup
local DeleteLayoutGroup = P.DeleteLayoutGroup
local DeleteDebuffGroup = P.DeleteDebuffGroup
local RemoveGroupMember = P.RemoveGroupMember
local SwapGroupMembers = P.SwapGroupMembers
local expandedCards = P.expandedCards
local tabButtons = P.tabButtons
local mainTabButtons = P.mainTabButtons
local effectCardPool = P.effectCardPool
local BADGE_COLORS = P.BADGE_COLORS
local placedIndicators = P.placedIndicators
local ClearPlacedIndicators = P.ClearPlacedIndicators
local RefreshPlacedIndicators = P.RefreshPlacedIndicators
local RefreshPreviewEffects = P.RefreshPreviewEffects
local CreateEnableBanner = P.CreateEnableBanner
local CreateSpecDropdown = P.CreateSpecDropdown
local CreateFramePreview = P.CreateFramePreview
local UpdateLayoutTabState = P.UpdateLayoutTabState
local UpdateSpecDropdownState = P.UpdateSpecDropdownState
local SetMainTab = P.SetMainTab
local OpenGroupSpellPicker = P.OpenGroupSpellPicker
local AddGroupAppearanceSection = P.AddGroupAppearanceSection

S.BuildLayoutGroupsTab = function()
    if not S.tabContentFrame then return end
    local parent = S.tabContentFrame
    local yPos = -10
    local tc = GetThemeColor()

    -- (Removed) a GROW_DIRECTIONS option map — never read. Also note its labels were
    -- raw English, so wiring it up as-is would have been a localisation regression.

    -- "+ Create Group" / "+ Filter Group" buttons (prominent, theme-colored).
    -- Left = classic member-arranger group; right = registry-linked filter group.
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab color
    local addBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addBtn:SetHeight(32)
    addBtn:SetPoint("TOPLEFT", 8, yPos)
    addBtn:SetPoint("TOPRIGHT", parent, "TOP", -2, yPos)
    GUI:StyleButton(addBtn, { height = 32, primary = true, accent = gc, text = L["+ Create Group"], font = "DFFontHighlight" })
    addBtn:SetScript("OnClick", function()
        local group = CreateLayoutGroup()
        if group then
            expandedGroups[GroupExpandKey(group.id)] = true
            S.SwitchTab("layout")
            RefreshPlacedIndicators()
        end
    end)

    local addFilterBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addFilterBtn:SetHeight(32)
    addFilterBtn:SetPoint("TOPLEFT", parent, "TOP", 2, yPos)
    addFilterBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, yPos)
    GUI:StyleButton(addFilterBtn, { height = 32, primary = true, accent = gc, text = L["+ Filter Group"], font = "DFFontHighlight" })
    addFilterBtn:SetScript("OnClick", function()
        local group = CreateLayoutGroup(nil, "filter")
        if group then
            expandedGroups[GroupExpandKey(group.id)] = true
            S.SwitchTab("layout")
            RefreshPlacedIndicators()
        end
    end)
    yPos = yPos - 42

    -- ── LAYOUT GROUPS heading — mirrors the Effects tab's ACTIVE INDICATORS
    -- caption and the Text Designer's group caption so every list tab has one. ──
    local groupsHeader = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(groupsHeader, 9, "")
    groupsHeader:SetPoint("TOPLEFT", 8, yPos)
    groupsHeader:SetText(L["LAYOUT GROUPS"])
    groupsHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 16

    -- Active tab's groups: the spec-keyed array on My Buffs, the flat
    -- spec-independent store on Other Buffs (read-only — visiting the tab
    -- never creates adDB.otherLayoutGroups; the add buttons do).
    local isOtherGroups = IsOtherTab()
    local groups = CurrentLayoutGroups()

    -- Display name lookup (My Buffs: the spec's trackable pool; Other Buffs:
    -- ad-hoc/SpellDB resolution — other-pool names aren't in a spec pool)
    local spec = ResolveSpec()
    local trackable = not isOtherGroups and spec and Adapter and Adapter:GetTrackableAuras(spec)
    local displayNames = {}
    if trackable then
        for _, info in ipairs(trackable) do
            displayNames[info.name] = info.display
        end
    end
    local function MemberDisplayName(auraName)
        if isOtherGroups then return OtherPoolDisplayName(auraName) end
        return displayNames[auraName] or auraName
    end

    if #groups == 0 then
        -- Empty state
        local empty = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        empty:SetPoint("TOP", parent, "TOP", 0, yPos - 30)
        empty:SetWidth(220)
        empty:SetText(L["No layout groups created yet.\nClick '+ Create Group' to get started."])
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        -- Render group cards (expansion keys are pool-scoped — raw id on My
        -- Buffs, "othergroup:<id>" on Other; the id counters overlap)
        for _, group in ipairs(groups) do
            local expandKey = GroupExpandKey(group.id)
            local isExpanded = expandedGroups[expandKey] or false

            -- ── CARD + HEADER ──
            local card, header, chevron = CreateCardShell(parent, {
                yPos          = yPos,
                expanded      = isExpanded,
                borderColor   = {r = gc.r * 0.35, g = gc.g * 0.35, b = gc.b * 0.35, a = 0.5},
                chevronColor  = gc,
            })

            -- Group name
            local nameText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            nameText:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
            nameText:SetPoint("RIGHT", header, "RIGHT", -60, 0)
            nameText:SetMaxLines(1)
            local isFilterGroup = (group.kind == "filter")
            if isFilterGroup then
                local linkCount = 0
                local fsel = group.filterSelection
                if fsel then
                    for _ in pairs(fsel.presets or {}) do linkCount = linkCount + 1 end
                    for _ in pairs(fsel.customs or {}) do linkCount = linkCount + 1 end
                end
                local fgInfo = group.name .. "  -  " .. linkCount .. (linkCount ~= 1 and L[" filters"] or L[" filter"])
                -- Collapsed-state Others Only suffix — mirror the effect-card header
                if isOtherGroups and group.othersOnly then
                    fgInfo = fgInfo .. "  -  " .. L["Others Only"]
                end
                nameText:SetText(fgInfo)
            else
                local memberCount = group.members and #group.members or 0
                nameText:SetText(group.name .. "  -  " .. memberCount .. (memberCount ~= 1 and L[" indicators"] or L[" indicator"]))
            end
            nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            -- Delete button
            local capturedGroupID = group.id
            local delBtn = GUI:CreateCloseButton(header, {
                size = 22,
                onClick = function()
                    DeleteLayoutGroup(capturedGroupID)
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                    -- Deleting a group deletes its member indicators — same
                    -- structural refresh as the effect-card delete / eye toggle.
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end,
            })
            delBtn:SetPoint("RIGHT", -4, 0)
            delBtn:SetFrameLevel(header:GetFrameLevel() + 2)

            -- Eye icon (visibility toggle) — filter groups only; same asset + toggle
            -- idiom as the effect-card eye (A3). enabled == false is hidden; nil/true
            -- = shown. Toggling is STRUCTURAL: the factory tears down / stands up the
            -- group container and the buff-row dedup union changes.
            if isFilterGroup then
                local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
                local eyeBtn = DF.GUI:CreateGlyphButton(header, { size = 18 })
                eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
                local function shown() return group.enabled ~= false end
                -- SetGlyph makes the state colour the new REST colour, so OnLeave
                -- restores the state; hover is suppressed while hidden.
                local function updateEyeIcon()
                    if shown() then
                        eyeBtn:SetGlyph(mediaPath .. "visibility", { 0.95, 0.95, 0.95 })
                    else
                        eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.45, 0.45, 0.45 })
                    end
                    eyeBtn:SetGlyphHover(shown())
                end
                updateEyeIcon()
                eyeBtn:RegisterForClicks("LeftButtonUp")
                eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
                eyeBtn:SetScript("OnClick", function()
                    group.enabled = (group.enabled == false) and true or false
                    updateEyeIcon()
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end)
                if not shown() then
                    nameText:SetAlpha(0.5)
                end
            end

            -- Header click → toggle expansion
            header:SetScript("OnClick", function()
                expandedGroups[expandKey] = not expandedGroups[expandKey]
                S.SwitchTab("layout")
            end)
            header:SetScript("OnEnter", function(self)
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
            end)
            header:SetScript("OnLeave", function(self)
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end)

            local totalCardH = 30

            -- ── BODY (when expanded) ──
            if isExpanded then
                local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
                body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
                body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
                ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
                    {r = gc.r * 0.20, g = gc.g * 0.20, b = gc.b * 0.20, a = 0.3})

                local by = -10
                local bodyWidth = (S.tabContentFrame and S.tabContentFrame:GetWidth() or 260) - 24
                if bodyWidth < 100 then bodyWidth = 240 end

                -- Group Name (editable)
                local nameLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(nameLabel, 8, "")
                nameLabel:SetPoint("TOPLEFT", 8, by)
                nameLabel:SetText(L["GROUP NAME"])
                nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 16

                local nameEdit = CreateFrame("EditBox", nil, body, "BackdropTemplate")
                nameEdit:SetHeight(22)
                nameEdit:SetPoint("TOPLEFT", 8, by)
                nameEdit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                nameEdit:SetAutoFocus(false)
                nameEdit:SetText(group.name)
                nameEdit:SetMaxLetters(30)
                GUI:StyleEditBox(nameEdit, {})
                nameEdit:SetScript("OnEnterPressed", function(self)
                    local val = self:GetText()
                    if val and val ~= "" then
                        group.name = val
                    end
                    self:ClearFocus()
                    S.SwitchTab("layout")
                end)
                nameEdit:SetScript("OnEscapePressed", function(self)
                    self:SetText(group.name)
                    self:ClearFocus()
                end)
                by = by - 32

                if isFilterGroup then
                -- ── LINKED FILTERS SECTION (filter groups) ──
                -- One collapsed chip per linked registry filter: localized preset name
                -- (or custom filter name) + live spell count, remove ✕. Links are stable
                -- REFERENCES (preset keys / custom ids) — never copies — so filter edits
                -- propagate live. Link/unlink is structural (container rebuild + the
                -- buff-row dedup union moves), so run the full refresh path.
                local R = DF.FilterRegistry
                local fsel = group.filterSelection
                if not fsel then fsel = {}; group.filterSelection = fsel end
                fsel.presets = fsel.presets or {}
                fsel.customs = fsel.customs or {}

                local function StructuralFilterRefresh()
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end

                local lfLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(lfLabel, 8, "")
                lfLabel:SetPoint("TOPLEFT", 8, by)
                lfLabel:SetText(L["LINKED FILTERS"])
                lfLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                -- Custom-filter spell count (curated spells + raw IDs)
                local function CustomFilterCount(cf)
                    local n = 0
                    if cf then
                        for _ in pairs(cf.spells or {}) do n = n + 1 end
                        for _ in pairs(cf.rawIDs or {}) do n = n + 1 end
                    end
                    return n
                end

                -- Linked list: presets in R.Categories order, then customs name-sorted.
                local linked = {}
                for _, cat in ipairs(R.Categories) do
                    if fsel.presets[cat.key] then
                        local enabled, total = R:PresetCounts(cat.key)
                        tinsert(linked, { kind = "preset", key = cat.key,
                            label = format("%s |cff888888(%d/%d)|r", L[cat.name], enabled, total) })
                    end
                end
                local linkedCustoms = {}
                for cfId in pairs(fsel.customs) do tinsert(linkedCustoms, cfId) end
                sort(linkedCustoms, function(a, b)
                    local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
                    local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
                    if na ~= nb then return na < nb end
                    return a < b
                end)
                for _, cfId in ipairs(linkedCustoms) do
                    local cf = R:GetCustomFilter(cfId)
                    tinsert(linked, { kind = "custom", key = cfId,
                        label = format("%s |cff888888(%d)|r", (cf and cf.name) or cfId, CustomFilterCount(cf)) })
                end

                if #linked > 0 then
                    for _, link in ipairs(linked) do
                        local chipRow = CreateFrame("Frame", nil, body, "BackdropTemplate")
                        chipRow:SetHeight(24)
                        chipRow:SetPoint("TOPLEFT", 8, by)
                        chipRow:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                        ApplyBackdrop(chipRow,
                            {r = 0.11, g = 0.11, b = 0.11, a = 1},
                            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

                        -- Remove ✕ (mirror the member-row remove idiom)
                        local remBtn = DF.GUI:CreateGlyphButton(chipRow, {
                            size = 18, iconSize = 12,
                            texture    = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close",
                            color      = { 0.55, 0.30, 0.30 },
                            hoverColor = { 1, 0.40, 0.40 },
                        })
                        remBtn:SetPoint("RIGHT", -4, 0)
                        local capturedLink = link
                        remBtn:SetScript("OnClick", function()
                            if capturedLink.kind == "preset" then
                                fsel.presets[capturedLink.key] = nil
                            else
                                fsel.customs[capturedLink.key] = nil
                            end
                            StructuralFilterRefresh()
                        end)

                        local chipText = chipRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                        chipText:SetPoint("LEFT", 8, 0)
                        chipText:SetPoint("RIGHT", remBtn, "LEFT", -4, 0)
                        chipText:SetMaxLines(1)
                        chipText:SetJustifyH("LEFT")
                        chipText:SetText(link.label)
                        chipText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                        by = by - 28
                    end
                else
                    local noLinks = body:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                    noLinks:SetPoint("TOPLEFT", 12, by)
                    noLinks:SetText(L["No filters linked yet"])
                    noLinks:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
                    by = by - 20
                end

                -- "+ Add Filter" button → mini-picker of unlinked presets + customs
                by = by - 6
                local addFilterLinkBtn = CreateFrame("Button", nil, body, "BackdropTemplate")
                addFilterLinkBtn:SetHeight(22)
                addFilterLinkBtn:SetPoint("TOPLEFT", 8, by)
                addFilterLinkBtn:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                GUI:StyleButton(addFilterLinkBtn, { height = 22, primary = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add Filter"] })
                GUI:SetSettingsFont(addFilterLinkBtn.Text, 9, "")
                addFilterLinkBtn:SetScript("OnClick", function()
                    -- Build the unlinked candidate list: presets (Categories order,
                    -- live counts), then customs (name-sorted). No Uncategorised
                    -- option by design — a group must resolve to an include map.
                    local candidates = {}
                    for _, cat in ipairs(R.Categories) do
                        if not fsel.presets[cat.key] then
                            local enabled, total = R:PresetCounts(cat.key)
                            tinsert(candidates, { kind = "preset", key = cat.key,
                                label = format("%s |cff888888(%d/%d)|r", L[cat.name], enabled, total) })
                        end
                    end
                    local freeCustoms = {}
                    for cfId in pairs(R:GetStore().customFilters) do
                        if not fsel.customs[cfId] then tinsert(freeCustoms, cfId) end
                    end
                    sort(freeCustoms, function(a, b)
                        local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
                        local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
                        if na ~= nb then return na < nb end
                        return a < b
                    end)
                    for _, cfId in ipairs(freeCustoms) do
                        local cf = R:GetCustomFilter(cfId)
                        tinsert(candidates, { kind = "custom", key = cfId,
                            label = format("%s |c%s(%s)|r", (cf and cf.name) or cfId, GUI:ToneHex("info"), L["Custom"]) })
                    end

                    -- Create/reuse the picker dropdown (same overlay/ESC/scroll idiom
                    -- as the member picker above)
                    local dropName = "DFADFilterGroupPicker"
                    local drop = _G[dropName]
                    if not drop then
                        drop = CreateFrame("Frame", dropName, UIParent, "BackdropTemplate")
                        drop:SetFrameStrata("FULLSCREEN_DIALOG")
                        drop:SetClampedToScreen(true)
                        local overlay = CreateFrame("Button", nil, UIParent)
                        overlay:SetAllPoints(UIParent)
                        overlay:SetFrameStrata("FULLSCREEN")
                        overlay:Hide()
                        overlay:SetScript("OnClick", function()
                            drop:Hide()
                            overlay:Hide()
                        end)
                        drop._overlay = overlay
                        -- SetPropagateKeyboardInput is protected in combat for
                        -- insecure code: skip the calls there (keys propagate
                        -- anyway — ESC just hides the dropdown), and don't trap
                        -- keyboard input if built mid-combat.
                        if not InCombatLockdown() then
                            drop:EnableKeyboard(true)
                            drop:SetPropagateKeyboardInput(true)
                        end
                        drop:SetScript("OnKeyDown", function(self, key)
                            if key == "ESCAPE" then
                                if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
                                self:Hide()
                            else
                                if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
                            end
                        end)
                        drop:SetScript("OnHide", function(self)
                            self._ownerBtn = nil
                            if self._overlay then self._overlay:Hide() end
                        end)
                    end
                    if drop:IsShown() and drop._ownerBtn == addFilterLinkBtn then
                        drop:Hide()
                        return
                    end
                    drop._ownerBtn = addFilterLinkBtn

                    local DROP_W = 240
                    local MAX_H = 300
                    drop:SetWidth(DROP_W)
                    ApplyBackdrop(drop, C_BACKGROUND, C_BORDER)

                    if not drop._scrollFrame then
                        local sf = CreateFrame("ScrollFrame", nil, drop)
                        sf:SetPoint("TOPLEFT", 0, 0)
                        sf:SetPoint("BOTTOMRIGHT", 0, 0)
                        drop._scrollFrame = sf
                        local sc = CreateFrame("Frame", nil, sf)
                        sc:SetWidth(DROP_W)
                        sf:SetScrollChild(sc)
                        drop._scrollChild = sc
                        sf:SetScript("OnMouseWheel", function(self2, delta2)
                            local cur = self2:GetVerticalScroll()
                            local maxS = max(0, self2:GetVerticalScrollRange())
                            self2:SetVerticalScroll(max(0, min(maxS, cur - (delta2 * 24))))
                        end)
                    end
                    local scrollChild = drop._scrollChild
                    local scrollFrame = drop._scrollFrame
                    scrollChild:SetWidth(DROP_W)
                    for _, child in ipairs({scrollChild:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                    for _, rgn in ipairs({scrollChild:GetRegions()}) do
                        if rgn:GetObjectType() == "FontString" or rgn:GetObjectType() == "Texture" then rgn:Hide() end
                    end
                    scrollFrame:Show()
                    scrollChild:EnableMouseWheel(true)
                    scrollChild:SetScript("OnMouseWheel", function(_, delta2)
                        scrollFrame:GetScript("OnMouseWheel")(scrollFrame, delta2)
                    end)

                    local dy2 = -4
                    if #candidates == 0 then
                        local none = scrollChild:CreateFontString(nil, "OVERLAY")
                        GUI:SetSettingsFont(none, 9, "")
                        none:SetPoint("TOPLEFT", 8, dy2 - 4)
                        none:SetText(L["No filters available"])
                        none:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
                        dy2 = dy2 - 24
                    end
                    for _, cand in ipairs(candidates) do
                        local ROW_H = 24
                        local row = CreateFrame("Button", nil, scrollChild)
                        row:SetHeight(ROW_H)
                        row:SetPoint("TOPLEFT", 4, dy2)
                        row:SetPoint("RIGHT", scrollChild, "RIGHT", -4, 0)

                        local rName = row:CreateFontString(nil, "OVERLAY")
                        GUI:SetSettingsFont(rName, 9, "")
                        rName:SetPoint("LEFT", 8, 0)
                        rName:SetText(cand.label)
                        rName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                        local hl = row:CreateTexture(nil, "BACKGROUND")
                        hl:SetAllPoints()
                        hl:SetColorTexture(1, 1, 1, 0)
                        row:SetScript("OnEnter", function() hl:SetColorTexture(1, 1, 1, 0.03) end)
                        row:SetScript("OnLeave", function() hl:SetColorTexture(1, 1, 1, 0) end)

                        local capturedCand = cand
                        row:SetScript("OnClick", function()
                            if capturedCand.kind == "preset" then
                                fsel.presets[capturedCand.key] = true
                            else
                                fsel.customs[capturedCand.key] = true
                            end
                            drop:Hide()
                            StructuralFilterRefresh()
                        end)
                        dy2 = dy2 - ROW_H
                    end
                    local totalH = -dy2 + 4
                    scrollChild:SetHeight(totalH)
                    drop:SetHeight(math.min(totalH, MAX_H))

                    drop:ClearAllPoints()
                    drop:SetPoint("TOPLEFT", addFilterLinkBtn, "BOTTOMLEFT", 0, -2)
                    drop:Show()
                    if drop._overlay then drop._overlay:Show() end
                end)
                by = by - 26

                -- "Create Filter" → jump to the Filter Designer and pulse its
                -- New Filter button, for users who arrive here without a custom
                -- filter to link yet.
                local createFilterBtn = CreateFrame("Button", nil, body, "BackdropTemplate")
                createFilterBtn:SetHeight(22)
                createFilterBtn:SetPoint("TOPLEFT", 8, by)
                createFilterBtn:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                GUI:StyleButton(createFilterBtn, { height = 22, text = L["Create Filter"] })
                GUI:SetSettingsFont(createFilterBtn.Text, 9, "")
                createFilterBtn:SetScript("OnClick", function()
                    if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
                        GUI.SelectTab("auras_filterdesigner")
                        -- Page content builds on first show (inside SelectTab), so
                        -- the button reference exists by now.
                        -- The add action is a row inside the Filter Designer's
                        -- scrolling left list, so the S.page scrolls it into view and
                        -- pulses it itself rather than handing back a bare widget.
                        local fdPage = GUI.Pages["auras_filterdesigner"]
                        if fdPage and fdPage._fdFocusNewFilter then
                            fdPage._fdFocusNewFilter()
                        end
                    end
                end)
                by = by - 28

                else
                -- ── MEMBERS SECTION ──
                local memLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(memLabel, 8, "")
                memLabel:SetPoint("TOPLEFT", 8, by)
                memLabel:SetText(L["MEMBERS"])
                memLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                if group.members and #group.members > 0 then
                    for mi, member in ipairs(group.members) do
                        local memberRow = CreateFrame("Frame", nil, body, "BackdropTemplate")
                        memberRow:SetHeight(34)
                        memberRow:SetPoint("TOPLEFT", 8, by)
                        memberRow:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                        ApplyBackdrop(memberRow,
                            {r = 0.11, g = 0.11, b = 0.11, a = 1},
                            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

                        -- Up/Down buttons for reordering (stacked vertically on left)
                        local canMoveUp = mi > 1
                        local canMoveDown = mi < #group.members
                        local capturedMi = mi

                        if canMoveUp then
                            -- One arrow texture serves both directions via rotation.
                            local upBtn = DF.GUI:CreateGlyphButton(memberRow, {
                                width = 20, height = 16, iconSize = 14,
                                texture  = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more",
                                rotation = math.rad(180),
                            })
                            upBtn:SetPoint("TOPLEFT", 2, -1)
                            upBtn:SetScript("OnClick", function()
                                SwapGroupMembers(capturedGroupID, capturedMi, capturedMi - 1)
                                S.SwitchTab("layout")
                                RefreshPlacedIndicators()
                                -- Positions moved (member index feeds the grid) — re-arrange live frames.
                                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                            end)
                        end
                        if canMoveDown then
                            local downBtn = DF.GUI:CreateGlyphButton(memberRow, {
                                width = 20, height = 16, iconSize = 14,
                                texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more",
                            })
                            downBtn:SetPoint("BOTTOMLEFT", 2, 1)
                            downBtn:SetScript("OnClick", function()
                                SwapGroupMembers(capturedGroupID, capturedMi, capturedMi + 1)
                                S.SwitchTab("layout")
                                RefreshPlacedIndicators()
                                -- Positions moved (member index feeds the grid) — re-arrange live frames.
                                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                            end)
                        end

                        -- Spell icon (Other: nil spec — GetAuraIcon degrades to
                        -- ad-hoc "#<id>" / SpellDB-by-name resolution)
                        local memberSpec = not isOtherGroups and ResolveSpec() or nil
                        local memberIconTex = GetAuraIcon(memberSpec, member.auraName)
                        local mSpellIcon = memberRow:CreateTexture(nil, "ARTWORK")
                        mSpellIcon:SetSize(22, 22)
                        mSpellIcon:SetPoint("LEFT", 26, 0)
                        if memberIconTex then
                            mSpellIcon:SetTexture(memberIconTex)
                            mSpellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        else
                            -- Color swatch fallback
                            local auraInfo2 = nil
                            local trackable2 = memberSpec and Adapter and Adapter:GetTrackableAuras(memberSpec)
                            if trackable2 then
                                for _, ai in ipairs(trackable2) do
                                    if ai.name == member.auraName then auraInfo2 = ai; break end
                                end
                            end
                            if auraInfo2 then
                                mSpellIcon:SetColorTexture(auraInfo2.color[1] * 0.5, auraInfo2.color[2] * 0.5, auraInfo2.color[3] * 0.5, 1)
                            else
                                mSpellIcon:SetColorTexture(0.25, 0.25, 0.25, 1)
                            end
                        end

                        -- Type badge (members live in the group's pool = the
                        -- active tab's pool)
                        local memberType = nil
                        local memberAuraCfg = CurrentAuraPool()[member.auraName]
                        if memberAuraCfg and memberAuraCfg.indicators then
                            for _, ind in ipairs(memberAuraCfg.indicators) do
                                if ind.id == member.indicatorID then
                                    memberType = ind.type
                                    break
                                end
                            end
                        end
                        local mBadgeColor = BADGE_COLORS[memberType or "icon"] or BADGE_COLORS.icon
                        local mBadgeLabel = S.PLACED_TYPE_LABELS[memberType or "icon"] or "Icon"

                        local mBadge = CreateFrame("Frame", nil, memberRow, "BackdropTemplate")
                        mBadge:SetHeight(16)
                        mBadge:SetPoint("LEFT", mSpellIcon, "RIGHT", 4, 0)
                        ApplyBackdrop(mBadge,
                            {r = mBadgeColor.r * 0.20, g = mBadgeColor.g * 0.20, b = mBadgeColor.b * 0.20, a = 1},
                            {r = mBadgeColor.r * 0.45, g = mBadgeColor.g * 0.45, b = mBadgeColor.b * 0.45, a = 0.6})
                        local mBadgeText = mBadge:CreateFontString(nil, "OVERLAY")
                        GUI:SetSettingsFont(mBadgeText, 8, "OUTLINE")
                        mBadgeText:SetPoint("CENTER", 0, 0)
                        mBadgeText:SetText(mBadgeLabel)
                        mBadgeText:SetTextColor(1, 1, 1)
                        mBadge:SetWidth(max(mBadgeText:GetStringWidth() + 12, 32))

                        -- Remove button (using close icon)
                        -- Red at rest, brighter red on hover: an inline destructive remove.
                        local remBtn = DF.GUI:CreateGlyphButton(memberRow, {
                            size = 18, iconSize = 12,
                            texture    = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close",
                            color      = { 0.55, 0.30, 0.30 },
                            hoverColor = { 1, 0.40, 0.40 },
                        })
                        remBtn:SetPoint("RIGHT", -4, 0)
                        local capturedMember = member
                        remBtn:SetScript("OnClick", function()
                            RemoveGroupMember(capturedGroupID, capturedMember.auraName, capturedMember.indicatorID)
                            -- Also delete the placed indicator itself
                            RemoveIndicatorInstance(capturedMember.auraName, capturedMember.indicatorID)
                            S.SwitchTab("layout")
                            RefreshPlacedIndicators()
                            RefreshPreviewEffects()
                            -- Structural change: same full refresh as the
                            -- effect-card ✕ / group delete (indicator removed).
                            DF:InvalidateAuraLayout()
                            DF:UpdateAllFrames()
                            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                            end
                        end)

                        -- Customise button (navigates to Effects tab for this indicator)
                        -- Accent-tinted action button: persistent accent fill +
                        -- accent border + accent label at rest, accent-wash hover.
                        local custBtn = CreateFrame("Button", nil, memberRow, "BackdropTemplate")
                        custBtn:SetPoint("RIGHT", remBtn, "LEFT", -4, 0)
                        GUI:StyleButton(custBtn, {
                            width = 56, height = 18,
                            text = L["Customise"],
                            tinted = true,
                            accent = GetThemeColor(),
                        })
                        local capturedAuraName = member.auraName
                        local capturedIndID = member.indicatorID
                        custBtn:SetScript("OnClick", function()
                            -- Card keys embed the B1 pool prefix in the name
                            -- segment ("placed:other:<name>#<id>" on Other)
                            local cardKey = "placed:" .. PoolKeyPrefix() .. capturedAuraName .. "#" .. capturedIndID
                            wipe(expandedCards)
                            expandedCards[cardKey] = true
                            S.activeTab = "effects"
                            DF:AuraDesigner_RefreshPage()
                        end)

                        -- Aura name
                        local mName = memberRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                        mName:SetPoint("LEFT", mBadge, "RIGHT", 6, 0)
                        mName:SetPoint("RIGHT", custBtn, "LEFT", -4, 0)
                        mName:SetMaxLines(1)
                        mName:SetText(MemberDisplayName(member.auraName))
                        mName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                        by = by - 38
                    end
                else
                    local noMem = body:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                    noMem:SetPoint("TOPLEFT", 12, by)
                    noMem:SetText(L["No members yet"])
                    noMem:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
                    by = by - 20
                end

                -- "+ Add aura" button
                by = by - 6
                local addMemBtn = CreateFrame("Button", nil, body, "BackdropTemplate")
                addMemBtn:SetHeight(22)
                addMemBtn:SetPoint("TOPLEFT", 8, by)
                addMemBtn:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                GUI:StyleButton(addMemBtn, { height = 22, primary = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add aura"] })
                GUI:SetSettingsFont(addMemBtn.Text, 9, "")
                addMemBtn:SetScript("OnClick", function()
                    -- Shared spell picker, group context: searchable,
                    -- class/category-filterable rows + add-by-ID, each row
                    -- carrying Icon/Square buttons that create the indicator
                    -- and enrol it in this group in one click.
                    OpenGroupSpellPicker(capturedGroupID)
                end)
                by = by - 28
                end -- isFilterGroup / members branch

                -- ── PLACEMENT SECTION ──
                by = by - 10
                local placeLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(placeLabel, 8, "")
                placeLabel:SetPoint("TOPLEFT", 8, by)
                placeLabel:SetText(L["PLACEMENT"])
                placeLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                -- Use GUI widgets with the group table as the proxy
                local anchorDrop = GUI:CreateDropdown(body, L["Anchor"], OPTS.ANCHOR_OPTIONS, group, "anchor", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end)
                anchorDrop:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if anchorDrop.SetWidth then anchorDrop:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oxSlider = GUI:CreateSlider(body, L["Offset X"], -150, 150, 1, group, "offsetX", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                oxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if oxSlider.SetWidth then oxSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oySlider = GUI:CreateSlider(body, L["Offset Y"], -150, 150, 1, group, "offsetY", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                oySlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if oySlider.SetWidth then oySlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- ── GROWTH SECTION ──
                by = by - 10
                local growLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(growLabel, 8, "")
                growLabel:SetPoint("TOPLEFT", 8, by)
                growLabel:SetText(L["GROWTH"])
                growLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                -- Auto-migrate legacy single-direction values to new format
                local gd = group.growDirection or "RIGHT"
                if not gd:find("_") then
                    local LEGACY_MAP = { RIGHT = "RIGHT_DOWN", LEFT = "LEFT_DOWN", UP = "UP_RIGHT", DOWN = "DOWN_RIGHT" }
                    group.growDirection = LEGACY_MAP[gd] or "RIGHT_DOWN"
                end

                local growthControl = GUI:CreateGrowthControl(body, group, "growDirection", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end)
                growthControl:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if growthControl.SetWidth then growthControl:SetWidth(bodyWidth - 10) end
                by = by - 158

                local iprSlider = GUI:CreateSlider(body, L["Icons Per Row"], 1, 20, 1, group, "iconsPerRow", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                iprSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if iprSlider.SetWidth then iprSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local spacingSlider = GUI:CreateSlider(body, L["Spacing"], -5, 20, 1, group, "spacing", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                spacingSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if spacingSlider.SetWidth then spacingSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                if isFilterGroup then
                    -- Uniform per-group styling: one icon size + slot cap for every
                    -- spell the linked filters match (no per-spell styling by design).
                    local sizeSlider = GUI:CreateSlider(body, L["Icon Size"], 8, 64, 1, group, "iconSize", function()
                        RefreshPlacedIndicators()
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end, function()
                        RefreshPlacedIndicators()
                    end)
                    sizeSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                    if sizeSlider.SetWidth then sizeSlider:SetWidth(bodyWidth - 10) end
                    by = by - 54

                    -- Max Icons is STRUCTURAL (slot count is declared at container
                    -- build) — the factory Rebuild path handles it (OOC-deferred).
                    local maxSlider = GUI:CreateSlider(body, L["Max Icons"], 1, 20, 1, group, "maxIcons", function()
                        RefreshPlacedIndicators()
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end, function()
                        RefreshPlacedIndicators()
                    end)
                    maxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                    if maxSlider.SetWidth then maxSlider:SetWidth(bodyWidth - 10) end
                    by = by - 54

                    -- ── SORT (Wave 2) ── per-group sort is TUNING: the factory
                    -- re-applies it in place via ApplyTuning (OOC-immediate;
                    -- self-defers in combat) — no rebuild. The fields are
                    -- OPTIONAL on the group (othersOnly idiom): absent = the
                    -- family default "DEFAULT" (Blizzard slot order, the
                    -- pre-Wave-2 behaviour), read through a customGet so legacy
                    -- groups display correctly without a write-on-open.
                    local sortRefresh = function()
                        RefreshPlacedIndicators()
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                    local sortMineCb   -- forward capture: the dropdown greys it
                    local sortDrop = GUI:CreateDropdown(body, L["Sort Order"], OPTS.SORT_OPTIONS, nil, nil, function()
                        sortRefresh()
                        if sortMineCb then sortMineCb:SetEnabled(DF:SortOrderSupportsMineFirst(group.sortOrder or "DEFAULT")) end
                    end, function() return group.sortOrder or "DEFAULT" end,
                       function(v) group.sortOrder = v end)
                    sortDrop:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                    if sortDrop.SetWidth then sortDrop:SetWidth(bodyWidth - 10) end
                    by = by - 54

                    sortMineCb = GUI:CreateCheckbox(body, L["My Auras First"], group, "sortMineFirst", sortRefresh)
                    sortMineCb:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(-by))
                    sortMineCb:SetWidth(bodyWidth - 16)
                    sortMineCb.tooltip = L["Sort your own auras before other players'. Unavailable on Default (which already shows yours first) and on Order Applied (which keeps one fixed order)."]
                    sortMineCb:SetEnabled(DF:SortOrderSupportsMineFirst(group.sortOrder or "DEFAULT"))
                    by = by - 26

                    local sortRevCb = GUI:CreateCheckbox(body, L["Reverse Order"], group, "sortReverse", sortRefresh)
                    sortRevCb:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(-by))
                    sortRevCb:SetWidth(bodyWidth - 16)
                    sortRevCb.tooltip = L["Reverse the sort direction."]
                    by = by - 30

                    -- ── OTHERS ONLY (Other Buffs tab only — flat-store groups) ──
                    -- Same idiom as the effect-card checkbox: the group's filter
                    -- string ("HELPFUL|!PLAYER") binds at container build, so
                    -- toggling is STRUCTURAL (folded into the fgroup struct sig →
                    -- the factory Rebuilds), and the buff-row dedup union moves
                    -- (an othersOnly group's spells keep their row icon).
                    if isOtherGroups then
                        local ooCb = GUI:CreateCheckbox(body, L["Others Only"], group, "othersOnly", function()
                            S.SwitchTab("layout")
                            RefreshPlacedIndicators()
                            DF:InvalidateAuraLayout()
                            DF:UpdateAllFrames()
                            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                            end
                        end)
                        ooCb:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(-by))
                        ooCb:SetWidth(bodyWidth - 16)
                        ooCb.tooltip = L["Only show other players' casts of these buffs."]
                        by = by - 34
                    end

                    -- ── APPEARANCE (collapsible — the effect-card section idiom) ──
                    by = by - 10
                    by = AddGroupAppearanceSection(body, group, bodyWidth, by, expandKey)
                end

                local bodyH = -by + 12
                body:SetHeight(bodyH)
                totalCardH = totalCardH + bodyH
            end

            card:SetHeight(totalCardH)
            yPos = yPos - totalCardH - 5
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ============================================================
-- DEBUFFS TAB — DEBUFF CATEGORY GROUPS (C2)
-- Each card owns a SELECTION of the native 12.1 debuff categories (checkbox
-- picker reusing the Aura Filters debuff column's controls) plus the shared
-- filter-group layout controls. Groups are spec-independent
-- (adDB.debuffGroups; lazily created on the first add — visiting the tab
-- writes nothing). Categories claimed by an enabled group are dropped from
-- the main debuff bar (C1 row-claim dedup), so EVERY selection / eye /
-- delete / add edit runs the FULL structural chain: InvalidateAuraLayout
-- bumps the version the row's claim fold AND the factory's dgroup record
-- cache re-resolve on; UpdateAllFrames + ForceRefreshAllFrames re-drive the
-- live frames and AD containers. Card keys are "dgroup:<id>" in
-- expandedGroups — layout-group cards key by raw numeric id, so the string
-- prefix can never collide with them (the two id counters overlap).
-- ============================================================

S.BuildDebuffGroupsTab = function()
    if not S.tabContentFrame then return end
    local parent = S.tabContentFrame
    local yPos = -10
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab accent

    -- Category picker rows: the Aura Filters debuff column's exact L keys +
    -- tooltips, mapped onto group.selection's keys. Built per tab build so a
    -- runtime locale overlay is picked up (file-scope L tables freeze enUS).
    local CATEGORY_DEFS = {
        { key = "boss",         label = L["Boss Debuffs"],        tooltip = L["Debuffs applied by dungeon and raid bosses."] },
        { key = "role",         label = L["Role Debuffs"],        tooltip = L["Debuffs Blizzard flags as important for your role."] },
        { key = "priority",     label = L["Priority Debuffs"],    tooltip = L["Debuffs Blizzard flags as high priority."] },
        { key = "crowdControl", label = L["Crowd Control"],       tooltip = L["CC effects like stuns, roots, and incapacitates."] },
        { key = "raid",         label = L["Raid Debuffs"],        tooltip = L["Other debuffs Blizzard flags for raid frames."] },
        { key = "dispellable",  label = L["Dispellable Debuffs"], tooltip = L["Debuffs that can be dispelled. Use the dropdown below to choose which dispels count."] },
    }

    -- FULL structural refresh incl. tab rebuild — discrete edits (category
    -- checkboxes, dispel mode, hide-long controls, eye, delete, add): the
    -- claims union moves AND the card summary / grey states must rebuild.
    local function StructuralDebuffGroupRefresh()
        S.SwitchTab("layout")
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end

    -- Same structural chain WITHOUT the tab rebuild — slider/dropdown-safe
    -- (a S.SwitchTab from inside a slider callback destroys the widget
    -- mid-interaction). Layout edits don't move the claims union, but the
    -- version bump keeps the factory's version-keyed dgroup record cache
    -- honest and costs one sig-gated re-resolve (offsets → ApplyStyle,
    -- maxIcons → Rebuild).
    local function LayoutDebuffGroupRefresh()
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end

    -- "+ Debuff Group" (prominent, tab accent — mirrors "+ Create Group").
    -- The debuffGroups array is born lazily on this first add.
    local addBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addBtn:SetHeight(32)
    addBtn:SetPoint("TOPLEFT", 8, yPos)
    addBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, yPos)
    GUI:StyleButton(addBtn, { height = 32, primary = true, accent = gc, text = L["+ Debuff Group"], font = "DFFontHighlight" })
    addBtn:SetScript("OnClick", function()
        local group = CreateDebuffGroup()
        if group then
            expandedGroups["dgroup:" .. group.id] = true
            -- A new group claims Boss + Role by default, so the main debuff
            -- bar drops them immediately: full structural chain, not just a
            -- tab rebuild.
            StructuralDebuffGroupRefresh()
        end
    end)
    yPos = yPos - 42

    -- Dedup explainer (§11.1 mock): how the row-claim handoff behaves.
    local dedupHint = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    dedupHint:SetPoint("TOPLEFT", 8, yPos)
    dedupHint:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    dedupHint:SetJustifyH("LEFT")
    dedupHint:SetWordWrap(true)
    dedupHint:SetText(L["Categories shown here are hidden from the main debuff bar automatically."])
    dedupHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 30

    -- ── DEBUFF GROUPS heading — mirrors the Layout Groups tab's caption. ──
    local groupsHeader = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(groupsHeader, 9, "")
    groupsHeader:SetPoint("TOPLEFT", 8, yPos)
    groupsHeader:SetText(L["DEBUFF GROUPS"])
    groupsHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 16

    -- READ path: visiting the tab never creates adDB.debuffGroups.
    local groups = DebuffGroupsRead()

    if #groups == 0 then
        -- Empty state
        local empty = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        empty:SetPoint("TOP", parent, "TOP", 0, yPos - 30)
        empty:SetWidth(220)
        empty:SetText(L["No debuff groups created yet.\nClick '+ Debuff Group' to get started."])
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        for _, group in ipairs(groups) do
            local cardKey = "dgroup:" .. group.id
            local isExpanded = expandedGroups[cardKey] or false
            local capturedGroupID = group.id

            -- ── CARD + HEADER ──
            local card, header, chevron = CreateCardShell(parent, {
                yPos          = yPos,
                expanded      = isExpanded,
                borderColor   = {r = gc.r * 0.35, g = gc.g * 0.35, b = gc.b * 0.35, a = 0.5},
                chevronColor  = gc,
            })

            -- Group name + collapsed summary: the selected category names
            -- (the A5 collapsed treatment, categories instead of link count).
            local nameText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            nameText:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
            nameText:SetPoint("RIGHT", header, "RIGHT", -60, 0)
            nameText:SetMaxLines(1)
            local selectedNames = {}
            local selRead = group.selection
            if selRead then
                for _, def in ipairs(CATEGORY_DEFS) do
                    if selRead[def.key] then tinsert(selectedNames, def.label) end
                end
            end
            local summary = (#selectedNames > 0) and table.concat(selectedNames, ", ")
                or L["No categories selected"]
            nameText:SetText(group.name .. "  -  " .. summary)
            nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            -- Delete button — full structural chain: the group's claimed
            -- categories return to the main debuff bar.
            local delBtn = GUI:CreateCloseButton(header, {
                size = 22,
                onClick = function()
                    DeleteDebuffGroup(capturedGroupID)
                    StructuralDebuffGroupRefresh()
                end,
            })
            delBtn:SetPoint("RIGHT", -4, 0)
            delBtn:SetFrameLevel(header:GetFrameLevel() + 2)

            -- Eye icon (visibility toggle) — same asset + idiom as the filter
            -- group eye (A3/A5). Toggling is STRUCTURAL: the factory tears
            -- down / stands up the container and the claims union moves.
            local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
            local eyeBtn = DF.GUI:CreateGlyphButton(header, { size = 18 })
            eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
            local function shown() return group.enabled ~= false end
            -- SetGlyph makes the state colour the new REST colour, so OnLeave
            -- restores the state; hover is suppressed while hidden.
            local function updateEyeIcon()
                if shown() then
                    eyeBtn:SetGlyph(mediaPath .. "visibility", { 0.95, 0.95, 0.95 })
                else
                    eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.45, 0.45, 0.45 })
                end
                eyeBtn:SetGlyphHover(shown())
            end
            updateEyeIcon()
            eyeBtn:RegisterForClicks("LeftButtonUp")
            eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
            eyeBtn:SetScript("OnClick", function()
                group.enabled = (group.enabled == false) and true or false
                updateEyeIcon()
                StructuralDebuffGroupRefresh()
            end)
            if not shown() then
                nameText:SetAlpha(0.5)
            end

            -- Header click → toggle expansion
            header:SetScript("OnClick", function()
                expandedGroups[cardKey] = not expandedGroups[cardKey]
                S.SwitchTab("layout")
            end)
            header:SetScript("OnEnter", function(self)
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
            end)
            header:SetScript("OnLeave", function(self)
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end)

            local totalCardH = 30

            -- ── BODY (when expanded) ──
            if isExpanded then
                local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
                body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
                body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
                ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
                    {r = gc.r * 0.20, g = gc.g * 0.20, b = gc.b * 0.20, a = 0.3})

                local by = -10
                local bodyWidth = (S.tabContentFrame and S.tabContentFrame:GetWidth() or 260) - 24
                if bodyWidth < 100 then bodyWidth = 240 end

                -- Repair a missing selection table (hand-edited data). All
                -- categories start FALSE so an unconfigured group renders —
                -- and claims — nothing until the user picks; modifier
                -- defaults mirror CreateDebuffGroup.
                local sel = group.selection
                if not sel then
                    sel = { dispellableMode = "PLAYER", hideLongMinutes = 5, keepImportant = true }
                    group.selection = sel
                end

                -- Group Name (editable)
                local nameLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(nameLabel, 8, "")
                nameLabel:SetPoint("TOPLEFT", 8, by)
                nameLabel:SetText(L["GROUP NAME"])
                nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 16

                local nameEdit = CreateFrame("EditBox", nil, body, "BackdropTemplate")
                nameEdit:SetHeight(22)
                nameEdit:SetPoint("TOPLEFT", 8, by)
                nameEdit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                nameEdit:SetAutoFocus(false)
                nameEdit:SetText(group.name)
                nameEdit:SetMaxLetters(30)
                GUI:StyleEditBox(nameEdit, {})
                nameEdit:SetScript("OnEnterPressed", function(self)
                    local val = self:GetText()
                    if val and val ~= "" then
                        group.name = val
                    end
                    self:ClearFocus()
                    -- Name feeds no sig — cosmetic only (header + canvas label).
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                end)
                nameEdit:SetScript("OnEscapePressed", function(self)
                    self:SetText(group.name)
                    self:ClearFocus()
                end)
                by = by - 32

                -- ── CATEGORIES SECTION ──
                -- Checkbox list writing group.selection.* — every toggle is
                -- structural (records move AND the claims union moves).
                local catLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(catLabel, 8, "")
                catLabel:SetPoint("TOPLEFT", 8, by)
                catLabel:SetText(L["CATEGORIES"])
                catLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                for _, def in ipairs(CATEGORY_DEFS) do
                    local cb = GUI:CreateCheckbox(body, def.label, sel, def.key, StructuralDebuffGroupRefresh)
                    cb:SetPoint("TOPLEFT", 8, by)
                    cb.tooltip = def.tooltip
                    by = by - 26

                    if def.key == "dispellable" then
                        -- Mode dropdown, indented under Dispellable Debuffs
                        -- (the Aura Filters column's control, group-scoped;
                        -- was a two-state toggle until the PTR-5 DISPELLABLE
                        -- token added the third "Any Dispel Type" mode).
                        local modeDrop = GUI:CreateDropdown(body, L["Mode"], {
                            PLAYER = L["Dispellable By Me"],
                            ALL = L["All Dispellable"],
                            ANY = L["Any Dispel Type"],
                            _order = { "PLAYER", "ALL", "ANY" },
                        }, sel, "dispellableMode", StructuralDebuffGroupRefresh)
                        modeDrop:SetPoint("TOPLEFT", 24, by)
                        if modeDrop.SetWidth then modeDrop:SetWidth(bodyWidth - 30) end
                        modeDrop.tooltip = L["Dispellable By Me: only debuffs you can dispel. All Dispellable: any debuff that can be dispelled. Any Dispel Type: every debuff with a dispel type, even ones that cannot be dispelled."]
                        modeDrop:SetEnabled(not not sel.dispellable)
                        by = by - 54
                    end
                end

                by = by - 4
                local hideLongCb = GUI:CreateCheckbox(body, L["Hide Long Debuffs"], sel, "hideLong", StructuralDebuffGroupRefresh)
                hideLongCb:SetPoint("TOPLEFT", 8, by)
                hideLongCb.tooltip = L["Hide debuffs whose total duration is longer than the threshold. Debuffs with no duration (permanent auras) are also hidden while this is on."]
                by = by - 26

                local minSlider = GUI:CreateSlider(body, L["Hide Longer Than (minutes)"], 1, 30, 1,
                    sel, "hideLongMinutes", LayoutDebuffGroupRefresh)
                minSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 8, by)
                if minSlider.SetWidth then minSlider:SetWidth(bodyWidth - 10) end
                minSlider:SetEnabled(not not sel.hideLong)
                by = by - 54

                -- Keep-important, indented under Hide Long (Aura Filters idiom)
                local keepCb = GUI:CreateCheckbox(body, L["Keep important debuffs"], sel, "keepImportant", StructuralDebuffGroupRefresh)
                keepCb:SetPoint("TOPLEFT", 24, by)
                keepCb.tooltip = L["Boss, Role, and Priority debuffs stay visible even when their duration is over the threshold."]
                keepCb:SetEnabled(not not sel.hideLong)
                by = by - 30

                -- ── PLACEMENT SECTION ── (the shared filter-group layout controls)
                by = by - 10
                local placeLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(placeLabel, 8, "")
                placeLabel:SetPoint("TOPLEFT", 8, by)
                placeLabel:SetText(L["PLACEMENT"])
                placeLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                local anchorDrop = GUI:CreateDropdown(body, L["Anchor"], OPTS.ANCHOR_OPTIONS, group, "anchor", LayoutDebuffGroupRefresh)
                anchorDrop:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if anchorDrop.SetWidth then anchorDrop:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oxSlider = GUI:CreateSlider(body, L["Offset X"], -150, 150, 1, group, "offsetX",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                oxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if oxSlider.SetWidth then oxSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oySlider = GUI:CreateSlider(body, L["Offset Y"], -150, 150, 1, group, "offsetY",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                oySlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if oySlider.SetWidth then oySlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- ── GROWTH SECTION ──
                by = by - 10
                local growLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(growLabel, 8, "")
                growLabel:SetPoint("TOPLEFT", 8, by)
                growLabel:SetText(L["GROWTH"])
                growLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                local growthControl = GUI:CreateGrowthControl(body, group, "growDirection", LayoutDebuffGroupRefresh)
                growthControl:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if growthControl.SetWidth then growthControl:SetWidth(bodyWidth - 10) end
                by = by - 158

                local iprSlider = GUI:CreateSlider(body, L["Icons Per Row"], 1, 20, 1, group, "iconsPerRow",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                iprSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if iprSlider.SetWidth then iprSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local spacingSlider = GUI:CreateSlider(body, L["Spacing"], -5, 20, 1, group, "spacing",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                spacingSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if spacingSlider.SetWidth then spacingSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- Uniform per-group styling (filter-group idiom: one icon
                -- size + slot cap for everything the categories match).
                local sizeSlider = GUI:CreateSlider(body, L["Icon Size"], 8, 64, 1, group, "iconSize",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                sizeSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if sizeSlider.SetWidth then sizeSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- Max Icons is STRUCTURAL (slot count is declared at container
                -- build) — the factory Rebuild path handles it (OOC-deferred).
                local maxSlider = GUI:CreateSlider(body, L["Max Icons"], 1, 20, 1, group, "maxIcons",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                maxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if maxSlider.SetWidth then maxSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- ── SORT (Wave 2) ── per-group sort is TUNING: the factory
                -- re-applies it in place via ApplyTuning (OOC-immediate;
                -- self-defers in combat) — no rebuild. Fields are OPTIONAL on
                -- the group (othersOnly idiom): absent = the family default
                -- "TIME" (soonest-to-expire first — the old hardcode), read
                -- through a customGet so legacy groups display correctly
                -- without a write-on-open.
                local sortMineCb   -- forward capture: the dropdown greys it
                local sortDrop = GUI:CreateDropdown(body, L["Sort Order"], OPTS.SORT_OPTIONS, nil, nil, function()
                    LayoutDebuffGroupRefresh()
                    if sortMineCb then sortMineCb:SetEnabled(DF:SortOrderSupportsMineFirst(group.sortOrder or "TIME")) end
                end, function() return group.sortOrder or "TIME" end,
                   function(v) group.sortOrder = v end)
                sortDrop:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if sortDrop.SetWidth then sortDrop:SetWidth(bodyWidth - 10) end
                by = by - 54

                sortMineCb = GUI:CreateCheckbox(body, L["My Auras First"], group, "sortMineFirst", LayoutDebuffGroupRefresh)
                sortMineCb:SetPoint("TOPLEFT", 8, by)
                sortMineCb:SetWidth(bodyWidth - 16)
                sortMineCb.tooltip = L["Sort your own auras before other players'. Unavailable on Default (which already shows yours first) and on Order Applied (which keeps one fixed order)."]
                sortMineCb:SetEnabled(DF:SortOrderSupportsMineFirst(group.sortOrder or "TIME"))
                by = by - 26

                local sortRevCb = GUI:CreateCheckbox(body, L["Reverse Order"], group, "sortReverse", LayoutDebuffGroupRefresh)
                sortRevCb:SetPoint("TOPLEFT", 8, by)
                sortRevCb:SetWidth(bodyWidth - 16)
                sortRevCb.tooltip = L["Reverse the sort direction."]
                by = by - 30

                -- ── APPEARANCE (collapsible — the effect-card section idiom) ──
                by = by - 10
                by = AddGroupAppearanceSection(body, group, bodyWidth, by, cardKey)

                local bodyH = -by + 12
                body:SetHeight(bodyH)
                totalCardH = totalCardH + bodyH
            end

            card:SetHeight(totalCardH)
            yPos = yPos - totalCardH - 5
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildAuraDesignerPage(guiRef, pageRef, dbRef)
    local prevDB = S.db  -- capture before overwrite to detect mode switch
    S.page = pageRef
    S.db = dbRef

    local parent = S.page.child

    -- ========================================
    -- REUSE: If S.mainFrame already exists, S.db hasn't changed (same mode) AND the
    -- frame dimensions are unchanged, just re-parent, show, and refresh. A mode
    -- switch (Party↔Raid) changes S.db; an auto-layout switch keeps the SAME S.db
    -- reference but changes frameWidth/Height — both must force a full rebuild so
    -- the preview mock resizes to the active layout's frame size.
    -- ========================================
    local _adFDB = (DF.GetDB and DF:GetDB((GUI and GUI.SelectedMode) or "party")) or {}
    local _adW, _adH = _adFDB.frameWidth or 125, _adFDB.frameHeight or 64
    -- Auto-layout identity: two raid layouts share the SAME S.db proxy and may share
    -- frame dimensions, so neither check below distinguishes them — without this,
    -- switching between same-size raid layouts reuses the stale S.page.
    local _adLayout = (DF.AutoProfilesUI and (DF.AutoProfilesUI.editingProfile or DF.AutoProfilesUI.activeRuntimeProfile)) or nil
    -- Preset identity: switching the mode's preset keeps the same S.db/size/layout,
    -- so without this the stale S.page (bound to the old preset) would be reused.
    local _adPreset = DF.GetModeDesignerPresetName
        and DF:GetModeDesignerPresetName("aura", (GUI and GUI.SelectedMode) or "party")
    -- Editing identity: entering edit of the ACTIVE layout keeps the same table
    -- object (editingProfile == activeRuntimeProfile), so _adLayout alone
    -- misses the transition and the editing-banner offset is never applied.
    local _adEditing = (DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing()) or false
    if S.mainFrame and prevDB == dbRef
       and S.mainFrame.dfBuiltFrameW == _adW and S.mainFrame.dfBuiltFrameH == _adH
       and S.mainFrame.dfBuiltLayout == _adLayout
       and S.mainFrame.dfBuiltPreset == _adPreset
       and S.mainFrame.dfBuiltEditing == _adEditing then
        S.mainFrame:SetParent(parent)
        S.mainFrame:SetAllPoints()
        S.mainFrame:Show()
        DF:AuraDesigner_RefreshPage()
        return
    end

    -- Full build (first time, or mode switch)
    if S.mainFrame then
        S.mainFrame:Hide()
        S.mainFrame:SetParent(nil)
    end
    wipe(placedIndicators)
    wipe(expandedCards)
    wipe(effectCardPool)

    S.activeTab = "effects"
    S.activeBuffTab = "my"
    S.activeFilter = "all"
    -- A shared picker left open on the OLD S.rightPanel dies with it (its
    -- close hook may already have run via the ancestor hide); drop the
    -- handle so CloseADPicker can't poke a stale overlay.
    S.adPickerDirty = false
    S.adPickerHandle = nil

    -- Layout constants
    local BANNER_H = 68
    local BUFFTAB_H = 30    -- main pool tab strip (My Buffs / Other Buffs)
    local SECTION_GAP = 8

    -- ========================================
    -- MAIN FRAME
    -- ========================================
    S.mainFrame = CreateFrame("Frame", nil, parent)
    S.mainFrame:SetAllPoints()
    -- Record the frame dims this build was made for, so the reuse-guard above can
    -- detect an auto-layout switch (same S.db, different frameWidth/Height) and rebuild.
    S.mainFrame.dfBuiltFrameW = _adW
    S.mainFrame.dfBuiltFrameH = _adH
    S.mainFrame.dfBuiltLayout = _adLayout
    S.mainFrame.dfBuiltPreset = _adPreset
    S.mainFrame.dfBuiltEditing = _adEditing
    -- Closing the settings window (or leaving this S.page) hides S.mainFrame with
    -- no refresh pass, which would leave the rendered preview pool's border
    -- animations ticking on the external driver (it ticks hidden secretRect
    -- borders — see ClearPlacedIndicators). OnHide fires on effective-visibility
    -- loss, so an ancestor hide (window close, S.page switch) reaches it too; the
    -- reuse path re-renders via AuraDesigner_RefreshPage → RefreshPlacedIndicators
    -- on return. S.mainFrame is created fresh per full build (the old one is hidden
    -- and unparented above), so this hook lands exactly once per frame.
    S.mainFrame:HookScript("OnHide", ClearPlacedIndicators)

    -- Override RefreshStates: Aura Designer uses its own layout system.
    --
    -- This hook gets called by anything that walks the GUI parent chain
    -- looking for a S.page with RefreshStates+children — including
    -- CreateInfoBanner's TriggerHostRelayout after every measure cycle.
    -- AuraDesigner_RefreshPage is a heavyweight rebuild (destroys +
    -- recreates every effect card on the active tab), so firing it
    -- from a banner's auto-resize cascade meant: each new banner from
    -- S.BuildEffectsTab triggered SetText → schedule DoRecomputeHeight →
    -- TriggerHostRelayout → S.page:RefreshStates → AuraDesigner_RefreshPage
    -- → S.SwitchTab → S.BuildEffectsTab → create more banners → repeat at
    -- ~9 Hz, locking up the GUI the moment the perf-warning banner
    -- surfaced (because picking an animation triggered the chain).
    --
    -- The fix: only call AuraDesigner_RefreshPage when the S.page
    -- dimensions actually changed.  GUI window resize cases (the real
    -- reason this hook exists) still rebuild; banner-cascade-as-noop
    -- cases stop the loop.
    S.page.RefreshStates = function(self)
        local pageH = self:GetHeight()
        self.child:SetHeight(pageH)
        local newW = GUI.contentFrame and (GUI.contentFrame:GetWidth() - 30) or nil
        if self.child and newW then
            self.child:SetWidth(newW)
        end
        -- Keep parent scroll at 0 — only the right panel should scroll
        local parentScroll = self:GetParent()
        if parentScroll and parentScroll.SetVerticalScroll then
            parentScroll:SetVerticalScroll(0)
        end
        -- Skip the heavyweight rebuild when nothing actually changed —
        -- only fire it on genuine size transitions (window resize / tab
        -- switch / first show).
        if self._lastRefreshStatesH == pageH and self._lastRefreshStatesW == newW then
            -- Same-size revisit AFTER the OnHide hook cleared the canvas (tab
            -- away + back re-enters ONLY through RefreshCached -> here; the
            -- builder is cache-skipped). Repaint the pooled slots without the
            -- full S.page rebuild: slot restyling creates no banners, so the
            -- banner-cascade loop this early-out exists for cannot re-arm.
            if S.placedCleared then
                RefreshPlacedIndicators()
                RefreshPreviewEffects()
            end
            return
        end
        self._lastRefreshStatesH = pageH
        self._lastRefreshStatesW = newW
        DF:AuraDesigner_RefreshPage()
    end

    local yPos = -8  -- top gap; kept equal to the Text Designer's _tdTopY for a consistent header gap
    -- While editing a raid auto-layout, the AutoProfiles editing banner is a ~50px
    -- overlay anchored to the top of the content frame; this custom AD S.page lays
    -- its own content out from the top too, so push everything down to clear it
    -- (otherwise the editing banner sits on top of the enable banner / preset bar).
    if DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing() then
        yPos = -56
    end

    -- ========================================
    -- ENABLE BANNER (full width)
    -- ========================================
    S.enableBanner = CreateEnableBanner(S.mainFrame)
    S.enableBanner:SetPoint("TOPLEFT", S.mainFrame, "TOPLEFT", 0, yPos)
    S.enableBanner:SetPoint("TOPRIGHT", S.mainFrame, "TOPRIGHT", 0, yPos)

    -- No Copy / Sync pair here (every other mode-specific S.page has one). The one
    -- key this S.page owns is the template NAME, and the template bar below sets
    -- it directly — so Copy was "pick that name in the other tab" and Sync was a
    -- link that could only ever hold one name in step. Sharing is now stated and
    -- undone on the bar itself; see GUI:CreateDesignerPresetBar.

    -- ========================================
    -- PRESET BAR (which named preset this mode uses + library management)
    -- Rides row 2 of the enable banner (left side; the spec dropdown holds the
    -- right side). Compact icon buttons keep the row within the S.page width.
    -- ========================================
    if GUI.CreateDesignerPresetBar then
        local presetBar = GUI:CreateDesignerPresetBar(S.enableBanner, {
            kind = "aura",
            iconButtons = true,
            getMode = function() return (GUI and GUI.SelectedMode) or "party" end,
            onChange = function()
                -- Re-invoke the build NEXT frame: the dfBuiltPreset guard then
                -- forces a full rebuild so the editor rebinds to the newly chosen
                -- preset. Deferred so we don't tear down the bar from inside its
                -- own click handler.
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function()
                        if DF.BuildAuraDesignerPage then DF.BuildAuraDesignerPage(GUI, S.page, S.db) end
                        DF:InvalidateAuraLayout()
                        DF:UpdateAllFrames()
                        local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                        if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
                    end)
                end
            end,
        })
        -- Row 2 reflows (B2): the spec dropdown moved onto the tab strip, so
        -- the preset bar takes the whole row.
        presetBar:SetPoint("LEFT", S.enableBanner, "LEFT", 10, -18)
        presetBar:SetPoint("RIGHT", S.enableBanner, "RIGHT", -10, -18)
        S.enableBanner.presetBar = presetBar
    end

    yPos = yPos - (BANNER_H + SECTION_GAP)

    -- ========================================
    -- MAIN POOL TAB STRIP (B2/C2): My Buffs / Debuffs / Other Buffs, between the header
    -- banner and the workspace. Visually distinct from the right panel's
    -- underline sub-tabs: filled StyleButton pills, slightly larger, with the
    -- relocated spec dropdown on the strip's right end (per the prototype —
    -- the spec only applies to My Buffs).
    -- ========================================
    local buffTabBar = CreateFrame("Frame", nil, S.mainFrame)
    buffTabBar:SetHeight(BUFFTAB_H)
    buffTabBar:SetPoint("TOPLEFT", S.mainFrame, "TOPLEFT", 0, yPos)
    buffTabBar:SetPoint("TOPRIGHT", S.mainFrame, "TOPRIGHT", 0, yPos)

    -- The three pools differ on two axes the labels can't carry — WHOSE casts
    -- count, and whether the pool is per-spec — so each tab explains itself on
    -- hover. (Any Buff is caster-agnostic by default; "Others Only" is the
    -- per-effect opt-in that ignores your own casts.)
    local MAIN_TAB_DEFS = {
        { key = "my",      label = L["My Buffs"], tooltip = {
            L["Buffs from your own class, and only when you cast them."],
            L["Set up separately for each specialization."],
        } },
        { key = "debuffs", label = L["Debuffs"], tooltip = {
            L["Groups of debuffs picked by category — boss, crowd control, dispellable and so on — rather than one spell at a time."],
            L["Shared across all your specializations."],
        } },
        { key = "other",   label = L["Any Buff"], tooltip = {
            L["Any buff in the spell database, from any caster — including your own."],
            L["Turn on Others Only for an effect to ignore your own casts."],
            L["Shared across all your specializations."],
        } },
    }
    wipe(mainTabButtons)
    local prevMainBtn
    for _, def in ipairs(MAIN_TAB_DEFS) do
        local btn = CreateFrame("Button", nil, buffTabBar, "BackdropTemplate")
        GUI:StyleButton(btn, { height = BUFFTAB_H - 4, text = def.label, font = "DFFontHighlight" })
        btn.Text:ClearAllPoints()
        btn.Text:SetPoint("CENTER", 0, 0)
        btn:SetWidth(max(btn.Text:GetStringWidth() + 28, 96))
        if prevMainBtn then
            btn:SetPoint("LEFT", prevMainBtn, "RIGHT", 4, 0)
        else
            btn:SetPoint("LEFT", buffTabBar, "LEFT", 0, 0)
        end
        local capturedKey = def.key
        btn:SetScript("OnClick", function() SetMainTab(capturedKey) end)
        -- HookScript, not SetScript: StyleButton owns OnEnter/OnLeave for the
        -- hover wash, and replacing them would leave the tab stuck lit.
        local tipTitle, tipLines = def.label, def.tooltip
        btn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, { title = tipTitle, lines = tipLines })
        end)
        btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        btn:SetActive(S.activeBuffTab == def.key)
        mainTabButtons[def.key] = btn
        prevMainBtn = btn
    end

    -- Relocated spec dropdown (right end of the strip)
    local stripSpecLabel = buffTabBar:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    stripSpecLabel:SetText(L["Spec:"])
    stripSpecLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    S.specDropdown, S.specDropdownUpdate = CreateSpecDropdown(buffTabBar)
    S.specDropdown:SetSize(165, 22)
    S.specDropdown:SetPoint("RIGHT", buffTabBar, "RIGHT", -5, 0)
    stripSpecLabel:SetPoint("RIGHT", S.specDropdown, "LEFT", -4, 0)
    UpdateSpecDropdownState()

    yPos = yPos - (BUFFTAB_H + SECTION_GAP)

    -- ========================================
    -- 50/50 SPLIT: LEFT PANEL + RIGHT PANEL
    -- ========================================
    local splitContainer = CreateFrame("Frame", nil, S.mainFrame)
    splitContainer:SetPoint("TOPLEFT", S.mainFrame, "TOPLEFT", 0, yPos)
    splitContainer:SetPoint("BOTTOMRIGHT", S.mainFrame, "BOTTOMRIGHT", 0, 0)
    S.mainFrame.splitContainer = splitContainer

    -- ── LEFT PANEL (frame preview) ──
    S.leftPanel = CreateFrame("Frame", nil, splitContainer, "BackdropTemplate")
    S.leftPanel:SetPoint("TOPLEFT", 0, 0)
    S.leftPanel:SetPoint("BOTTOMLEFT", 0, 0)
    S.leftPanel:SetPoint("RIGHT", splitContainer, "CENTER", -3, 0)
    -- NO border here — the inner preview container (CreateFramePreview) draws the
    -- visible dim border. A border on both stacked to a brighter doubled line.
    GUI:CreatePanelBackdrop(S.leftPanel, {border = false})

    -- Frame preview (reuses existing CreateFramePreview with adapted anchoring)
    S.origY_framePreview = 0
    S.framePreview = CreateFramePreview(S.leftPanel, 0, nil)
    S.contentRightInset = 0  -- No right inset needed in new layout

    -- ── RIGHT PANEL (tabbed settings) ──
    S.rightPanel = CreateFrame("Frame", nil, splitContainer, "BackdropTemplate")
    S.rightPanel:SetPoint("TOPRIGHT", 0, 0)
    S.rightPanel:SetPoint("BOTTOMRIGHT", 0, 0)
    S.rightPanel:SetPoint("LEFT", splitContainer, "CENTER", 3, 0)  -- 6px split gap (matches Text Designer)
    GUI:CreatePanelBackdrop(S.rightPanel, {borderColor = {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5}})

    -- ── TAB BAR ── (shared underline-tab style, mirroring the Pinned Frames
    -- tabs: a transparent strip with a baseline; each tab is a StyleButton in
    -- `tab` mode — faint cell when inactive, accent fill + underline + accent
    -- label when active. Per-tab accent preserves each section's identity.)
    S.tabBar = CreateFrame("Frame", nil, S.rightPanel, "BackdropTemplate")
    S.tabBar:SetHeight(28)
    -- Inset just inside the panel's border so the tabs don't overlap/overrun it.
    S.tabBar:SetPoint("TOPLEFT", 4, -4)
    S.tabBar:SetPoint("TOPRIGHT", -4, -4)

    -- Baseline under the whole strip; the active tab's underline sits on it.
    local tabBaseline = S.tabBar:CreateTexture(nil, "ARTWORK")
    tabBaseline:SetTexture("Interface\\Buttons\\WHITE8x8")
    tabBaseline:SetHeight(1)
    tabBaseline:SetPoint("BOTTOMLEFT", 0, 0)
    tabBaseline:SetPoint("BOTTOMRIGHT", 0, 0)
    tabBaseline:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)

    local TAB_GAP = 4
    local TAB_DEFS = {
        { key = "effects", label = L["Effects"],       accent = nil },  -- theme-tracking
        { key = "layout",  label = L["Layout Groups"], accent = { r = 0.91, g = 0.66, b = 0.25 } },
        { key = "global",  label = L["Global"],        accent = { r = 0.51, g = 0.86, b = 0.51 } },
    }

    wipe(tabButtons)
    for i, def in ipairs(TAB_DEFS) do
        local btn = CreateFrame("Button", nil, S.tabBar, "BackdropTemplate")
        btn:SetHeight(28)
        if i == 1 then
            btn:SetPoint("TOPLEFT", 0, 0)
        else
            btn:SetPoint("TOPLEFT", tabButtons[TAB_DEFS[i-1].key], "TOPRIGHT", TAB_GAP, 0)
        end
        local provW = parent:GetWidth()
        if provW < 100 and GUI and GUI.contentFrame then provW = GUI.contentFrame:GetWidth() end
        if provW < 100 then provW = 600 end
        btn:SetWidth(max(60, floor(((provW / 2) - (#TAB_DEFS - 1) * TAB_GAP) / #TAB_DEFS)))

        -- Shared underline-tab styling; S.SwitchTab drives SetActive. label = btn.Text.
        GUI:StyleButton(btn, { tab = true, text = def.label, accent = def.accent, font = "DFFontHighlight" })
        btn.label = btn.Text

        btn.tabKey = def.key
        btn:SetScript("OnClick", function(self)
            if self.dfDisabled then return end  -- frosted (Effects on Debuffs)
            S.SwitchTab(self.tabKey)
        end)

        -- Effects is buff-pool-only (C2): frosted on the Debuffs tab —
        -- category groups have no per-spell placed indicators.
        if def.key == "effects" then
            btn:HookScript("OnEnter", function(self)
                if self.dfDisabled then
                    GUI:ShowTooltip(self, {
                        title = L["Effects"],
                        lines = { L["Not available for Debuffs. Use Layout Groups instead."] },
                    })
                end
            end)
            btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        end

        tabButtons[def.key] = btn
    end
    UpdateLayoutTabState()

    -- Equal-width tabs (accounting for the gaps) on parent resize.
    S.tabBar:SetScript("OnSizeChanged", function(self, w, h)
        local n = #TAB_DEFS
        local tabW = (w - (n - 1) * TAB_GAP) / n
        for _, def in ipairs(TAB_DEFS) do
            local btn = tabButtons[def.key]
            if btn then btn:SetWidth(tabW) end
        end
    end)

    -- ── TAB CONTENT (scrollable) ──
    S.tabScrollFrame = CreateFrame("ScrollFrame", nil, S.rightPanel, "ScrollFrameTemplate")
    S.tabScrollFrame:SetPoint("TOPLEFT", S.tabBar, "BOTTOMLEFT", 0, 0)
    S.tabScrollFrame:SetPoint("BOTTOMRIGHT", -22, 0)

    S.tabContentFrame = CreateFrame("Frame", nil, S.tabScrollFrame)
    -- Pre-compute initial width from parent geometry so S.SwitchTab() has
    -- accurate dimensions before the first layout pass fires OnSizeChanged.
    local earlyW = parent:GetWidth()
    if earlyW < 100 then earlyW = (GUI.contentFrame and GUI.contentFrame:GetWidth() or 600) - 30 end
    S.tabContentFrame:SetWidth(max(1, (earlyW / 2) - 2 - 22))
    S.tabContentFrame:SetHeight(800)
    S.tabScrollFrame:SetScrollChild(S.tabContentFrame)
    DF.GUI.StyleScrollBar(S.tabScrollFrame)

    -- Match scroll child width to scroll frame
    S.tabScrollFrame:SetScript("OnSizeChanged", function(self, w, h)
        S.tabContentFrame:SetWidth(w)
    end)

    -- Smooth scroll
    local SCROLL_STEP = 30
    S.tabScrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = max(0, self:GetVerticalScrollRange())
        local newScroll = max(0, min(maxScroll, current - (delta * SCROLL_STEP)))
        self:SetVerticalScroll(newScroll)
    end)
    S.tabContentFrame:EnableMouseWheel(true)
    S.tabContentFrame:SetScript("OnMouseWheel", function(self, delta)
        local p = self:GetParent()
        if p and p:GetScript("OnMouseWheel") then
            p:GetScript("OnMouseWheel")(p, delta)
        end
    end)

    -- ========================================
    -- POPULATE (new UI)
    -- ========================================

    -- Force initial width sync: OnSizeChanged won't fire until the frame renders,
    -- but S.SwitchTab needs accurate widths now for slider/dropdown sizing.
    -- Compute initial scroll content width from parent geometry.
    -- S.rightPanel:GetWidth() returns 0 before the first layout pass, so we
    -- calculate from the parent which already has valid geometry on a mode
    -- switch (Party↔Raid).
    local parentW = parent:GetWidth()
    if parentW < 100 and GUI and GUI.contentFrame then parentW = GUI.contentFrame:GetWidth() end
    if parentW < 100 then parentW = UIParent:GetWidth() / 2 end
    local initW = (parentW / 2) - 2 - 22  -- half split minus gap minus scrollbar
    if initW > 50 then
        S.tabContentFrame:SetWidth(initW)
    end

    S.SwitchTab("effects")
    C_Timer.After(0, function()
        if S.tabBar and S.tabBar:IsVisible() and S.tabBar:GetWidth() > 10 then
            local tabW = (S.tabBar:GetWidth() - (#TAB_DEFS - 1) * TAB_GAP) / #TAB_DEFS
            for _, def in ipairs(TAB_DEFS) do
                if tabButtons[def.key] then
                    tabButtons[def.key]:SetWidth(tabW)
                end
            end
        end
    end)
    RefreshPlacedIndicators()
    RefreshPreviewEffects()
end

-- ============================================================
-- REFRESH
-- ============================================================

function DF:AuraDesigner_RefreshPage()
    if not S.mainFrame then return end

    -- Account for editing banner offset (50px) when editing an auto layout
    local editingOffset = 0
    if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
        editingOffset = 50
    end
    S.mainFrame:ClearAllPoints()
    S.mainFrame:SetPoint("TOPLEFT", S.mainFrame:GetParent(), "TOPLEFT", 0, -editingOffset)
    S.mainFrame:SetPoint("BOTTOMRIGHT", S.mainFrame:GetParent(), "BOTTOMRIGHT", 0, 0)

    -- Check if spec changed
    local currentSpec = ResolveSpec()
    if currentSpec ~= S.selectedSpec then
        S.selectedSpec = currentSpec
    end

    -- Subtle class-color hint on the preview border, dimmed to 0.5 alpha so it
    -- stays as quiet as the Text Designer's neutral border (just tinted to the
    -- spec). Was previously full alpha = the harsh "white line" (white for Priest).
    if S.framePreview then
        local resolvedSpec = currentSpec or S.selectedSpec
        local specInfoEntry = resolvedSpec and DF.AuraDesigner.SpecInfo[resolvedSpec]
        local classToken = specInfoEntry and specInfoEntry.class
        local classColor = classToken and RAID_CLASS_COLORS[classToken]
        if classColor then
            S.framePreview:SetBackdropBorderColor(classColor.r, classColor.g, classColor.b, 0.5)
        else
            S.framePreview:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        end
    end

    -- Rebuild the current tab to reflect data changes
    if S.activeTab and S.SwitchTab then
        S.SwitchTab(S.activeTab)
    end

    -- Refresh frame preview
    RefreshPlacedIndicators()
    RefreshPreviewEffects()

    -- Update enable state
    if S.enableBanner then
        S.enableBanner.checkbox:SetChecked(GetAuraDesignerDB().enabled)
    end
    -- Spec dropdown lives on the main tab strip (B2): refresh its text on
    -- My Buffs / keep the greyed "shared across specs" caption on Other Buffs.
    UpdateSpecDropdownState()

    -- Show/hide disabled overlay on the split container
    if S.mainFrame.splitContainer then
        local adEnabled = GetAuraDesignerDB().enabled
        if not adEnabled then
            if not S.mainFrame.disabledOverlay then
                -- Shared with the Text Designer and Raid Auto Layouts; this S.page
                -- only owns the extent (the whole split container) and the label.
                local overlay = GUI:CreateDisabledOverlay(S.mainFrame.splitContainer, {
                    label = L["Aura Designer is disabled"],
                })
                overlay:SetAllPoints()
                S.mainFrame.disabledOverlay = overlay
            end
            S.mainFrame.disabledOverlay:Show()
        else
            if S.mainFrame.disabledOverlay then
                S.mainFrame.disabledOverlay:Hide()
            end
        end
    end

    -- Refresh buffs tab banner state if visible
    local buffsPage = GUI and GUI.Pages and GUI.Pages["auras_buffs"]
    if buffsPage and buffsPage.RefreshStates then
        buffsPage:RefreshStates()
    end

    -- 12.1: the native factory buff row DERIVES its Aura-Designer dedup set from the AD
    -- config at build time. Indicator add/remove (and other config mutations) funnel
    -- through this refresh but do NOT otherwise re-drive live frames, so poke the buff
    -- row here — mirror the aura-blacklist S.page (InvalidateAuraLayout -> RefreshFactoryRows).
    -- DriveBuffFactory rebuilds only when the excluded set actually moved (sig-gated), so a
    -- navigation-only refresh is a cheap no-op. Factory-gated so the pre-12.1 path is untouched.
    if DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported()
        and DF.InvalidateAuraLayout then
        DF:InvalidateAuraLayout()
    end
end
