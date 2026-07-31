-- Part 2 of the settings pages, split from Options.lua.
-- The parts run as a chain so the pages build in their original order.
local addonName, DF = ...
local format = string.format
function DF._SetupGUIPagesPart2(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
    local pageGlobalFonts = CreateSubTab("general", "general_fonts", L["Global Fonts"])
    BuildPage(pageGlobalFonts, function(self, db, Add, AddSpace, AddSyncPoint)
        Add(CreateCopyButton(self.child, {"fontShadow"}, L["Global Fonts"], "general_fonts"), 25, 2)
        -- Initialize temp storage for selections (persists during session)
        if not DF.GlobalFontTemp then
            DF.GlobalFontTemp = {
                font = db.nameFont or "Fonts\\FRIZQT__.TTF",
                outline = db.nameTextOutline or "OUTLINE",
            }
        end
        
        -- ===== FONT SELECTION GROUP (Column 1) =====
        local fontSelectGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontSelectGroup:AddWidget(GUI:CreateHeader(self.child, L["Global Font Settings"]), 40)
        fontSelectGroup:AddWidget(GUI:CreateLabel(self.child, L["Set a font and outline style, then click Apply to update ALL text elements."], 250), 40)
        
        fontSelectGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], DF.GlobalFontTemp, "font", function() end), 55)
        
        fontSelectGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], DF.GlobalFontTemp, "outline", function() end), 55)
        fontSelectGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], DF.GlobalFontTemp, "outline", function() end), 30)
        
        -- Themed Apply button
        local applyBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        GUI:StyleButton(applyBtn, { width = 120, height = 28, text = L["Apply to All"] })
        applyBtn.text = applyBtn.Text
        applyBtn:SetScript("OnClick", function()
            local font = DF.GlobalFontTemp.font
            local outline = DF.GlobalFontTemp.outline
            
            -- Clear font family cache so new fonts are created
            if DF.ClearFontCache then DF:ClearFontCache() end
            
            -- Apply to all font settings
            db.nameFont = font; db.nameTextOutline = outline
            db.healthFont = font; db.healthTextOutline = outline
            db.statusTextFont = font; db.statusTextOutline = outline
            db.buffStackFont = font; db.buffStackOutline = outline
            db.buffDurationFont = font; db.buffDurationOutline = outline
            db.debuffStackFont = font; db.debuffStackOutline = outline
            db.debuffDurationFont = font; db.debuffDurationOutline = outline
            db.petNameFont = font; db.petNameFontOutline = outline
            db.petHealthFont = font; db.petHealthFontOutline = outline
            db.personalTargetedSpellDurationFont = font; db.personalTargetedSpellDurationOutline = outline
            db.targetedListFont = font; db.targetedListFontOutline = outline
            db.defensiveIconDurationFont = font; db.defensiveIconDurationOutline = outline
            db.statusIconFont = font; db.statusIconFontOutline = outline
            -- AFK timer text inherits the status-icon font; clear any per-timer
            -- override so it follows the freshly-applied global font.
            db.afkIconTimerFont = nil; db.afkIconTimerOutline = nil
            if db.groupLabelFont ~= nil then
                db.groupLabelFont = font; db.groupLabelOutline = outline
            end
            -- Aura Designer global defaults + clear per-instance overrides.
            -- AD config now lives in the preset this mode uses, not inline.
            -- BASE resolver: "apply font globally" edits the user's base
            -- preset — with a runtime auto-layout active, the ACTIVE resolver
            -- would mutate the layout's preset instead (editor model is BASE).
            local _adMode = (db == DF.db.raid) and "raid" or "party"
            local _adCfg = (DF.GetModeBaseAuraDesigner and DF:GetModeBaseAuraDesigner(_adMode))
                or (DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(_adMode))
            if _adCfg then
                if _adCfg.defaults then
                    local adDefaults = _adCfg.defaults
                    adDefaults.durationFont = font; adDefaults.durationOutline = outline
                    adDefaults.stackFont = font; adDefaults.stackOutline = outline
                end
                -- Clear per-instance font overrides so all indicators inherit global
                if _adCfg.auras then
                    for _, auraCfg in pairs(_adCfg.auras) do
                        if auraCfg.indicators then
                            for _, inst in ipairs(auraCfg.indicators) do
                                inst.durationFont = nil; inst.durationOutline = nil
                                inst.stackFont = nil; inst.stackOutline = nil
                            end
                        end
                    end
                end
            end

            -- Text Designer text elements: the legacy name/health/status
            -- fontstrings are retired (IsLegacyTextHidden), so the visible
            -- name/health/status text now comes from the Text Designer. Drive
            -- its elements too (BASE preset, matching the AD block above) so
            -- "Apply to All" actually changes that text.
            local _tdMode = (db == DF.db.raid) and "raid" or "party"
            local _tdCfg = (DF.GetModeBaseTextDesigner and DF:GetModeBaseTextDesigner(_tdMode))
                or (DF.GetModeTextDesigner and DF:GetModeTextDesigner(_tdMode))
            if _tdCfg then
                if _tdCfg.elements then
                    for _, el in ipairs(_tdCfg.elements) do
                        el.font = font; el.outline = outline
                    end
                end
                if _tdCfg.globalDefaults then
                    _tdCfg.globalDefaults.font = font
                    _tdCfg.globalDefaults.outline = outline
                end
            end

            DF:UpdateAllFrames()
            if GUI.SelectedMode == "raid" and DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestTargetedSpell then DF:UpdateAllTestTargetedSpell() end
            if DF.UpdateTestPersonalTargetedSpells then DF:UpdateTestPersonalTargetedSpells() end
            if DF.UpdateTargetedListLayout then DF:UpdateTargetedListLayout() end
            if DF.UpdateAllFramesStatusIcons then DF:UpdateAllFramesStatusIcons() end
            
            -- Refresh test frames to apply new fonts
            if DF.RefreshTestFrames then DF:RefreshTestFrames() end

            -- Force Aura Designer to re-apply indicators with new fonts
            if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
            -- Also refresh the AD options preview if visible
            if DF.AuraDesigner_RefreshPage then DF:AuraDesigner_RefreshPage() end

            -- Text Designer owns the live name/health/status text — re-render it.
            if DF.TextDesigner and DF.TextDesigner.Preview and DF.TextDesigner.Preview.RefreshLiveFrames then
                DF.TextDesigner.Preview:RefreshLiveFrames()
            end

            DF:Say("Applied global font settings to all text elements.")
        end)
        fontSelectGroup:AddWidget(applyBtn, 35)

        fontSelectGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Crisp Font Rendering (SDF)"], DF.db, "fontSlug", function()
            if DF.ClearFontCache then DF:ClearFontCache() end
            DF:UpdateAllFrames()
            if GUI.SelectedMode == "raid" and DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            if DF.RefreshTestFrames then DF:RefreshTestFrames() end
        end), 30)
        fontSelectGroup:AddWidget(GUI:CreateLabel(self.child, L["Renders text with signed-distance-field smoothing for sharper edges at any size. Applies to None and Outline styles only (not Monochrome, Thick, or Shadow)."], 250), 50)

        Add(fontSelectGroup, nil, 1)

        -- ===== SHADOW SETTINGS GROUP (Column 1) =====
        local shadowGroup = GUI:CreateSettingsGroup(self.child, 280)
        shadowGroup:AddWidget(GUI:CreateHeader(self.child, L["Shadow Settings"]), 40)
        shadowGroup:AddWidget(GUI:CreateLabel(self.child, L["These settings apply when using 'Shadow' outline style. Use larger offsets for more dramatic shadows."], 250), 40)
        
        local function UpdateShadowSettings()
            -- Full update on release
            if DF.ClearFontCache then DF:ClearFontCache() end
            DF:UpdateAllFrames()
            if GUI.SelectedMode == "raid" and DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            -- UpdateAllFrames doesn't reach the pinned pool — re-font it too.
            if DF.RefreshPinnedFonts then DF:RefreshPinnedFonts() end
            -- Re-render the Text Designer overlay (the visible text) so its shadow
            -- updates on pinned + live frames too.
            if DF.TextDesigner and DF.TextDesigner.Preview and DF.TextDesigner.Preview.RefreshLiveFrames then
                DF.TextDesigner.Preview:RefreshLiveFrames()
            end
        end
        
        local function LightweightShadowUpdate()
            if DF.LightweightUpdateFontShadows then DF:LightweightUpdateFontShadows() end
        end
        
        shadowGroup:AddWidget(GUI:CreateSlider(self.child, L["Shadow X Offset"], -10, 10, 0.5, db, "fontShadowOffsetX", UpdateShadowSettings, LightweightShadowUpdate), 50)
        shadowGroup:AddWidget(GUI:CreateSlider(self.child, L["Shadow Y Offset"], -10, 10, 0.5, db, "fontShadowOffsetY", UpdateShadowSettings, LightweightShadowUpdate), 50)
        shadowGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Shadow Color"], db, "fontShadowColor", true, UpdateShadowSettings, LightweightShadowUpdate, true), 40)
        
        Add(shadowGroup, nil, 1)
        
        -- ===== AFFECTED ELEMENTS GROUP (Column 2) =====
        local infoGroup = GUI:CreateSettingsGroup(self.child, 280)
        infoGroup:AddWidget(GUI:CreateHeader(self.child, L["Affected Elements"]), 40)
        infoGroup:AddWidget(GUI:CreateLabel(self.child, L["• Text Designer (Name, Health, Status & custom text)\n• Buff Stack & Duration\n• Debuff Stack & Duration\n• Pet Frame Text\n• Targeted Spell Duration\n• Defensive Icon Duration\n• All Icon Text (Res, Summon, etc.)\n• Group Labels (Raid)\n• Targeted List\n• Personal Targeted Spell\n• Aura Designer Indicators\n• Pinned Frames"], 250), 235)
        infoGroup:AddWidget(GUI:CreateNote(self.child, L["Font sizes are not changed. Adjust sizes in each element's page."], {tone = "caution", prefix = "Note", width = 250}), 40)
        Add(infoGroup, nil, 2)
    end)
    
    -- General > Group Labels (Raid only, group-based layout only)
    local pageGroupLabels = CreateSubTab("general", "general_labels", L["Group Labels"])
    BuildPage(pageGroupLabels, function(self, db, Add, AddSpace, AddSyncPoint)
        Add(CreateCopyButton(self.child, {"groupLabel"}, L["Group Labels"], "general_labels"), 25, 2)
        -- The dependent groups stay hidden under mode/variant gating (not raid,
        -- or flat layout), but when visible they GREY OUT (disabled-in-place)
        -- while the Enable toggle is off rather than vanishing.
        local function HideGroupLabelOptions()
            return GUI.SelectedMode ~= "raid" or not db.raidUseGroups
        end
        local function DisableGroupLabelOptions(d)
            return not d.groupLabelEnabled
        end

        local function UpdateLabels()
            if DF.UpdateRaidGroupLabels then DF:UpdateRaidGroupLabels() end
        end

        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Raid Group Labels"]), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Display labels above or beside each raid group."], 250), 25)
        local groupLabelEnable = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Group Labels"], db, "groupLabelEnabled", function()
            UpdateLabels()
            self:RefreshStates()
        end), 30)
        groupLabelEnable.keepEnabled = true
        settingsGroup.hideOn = HideGroupLabelOptions
        Add(settingsGroup, nil, 1)
        
        -- ===== TEXT FORMAT GROUP (Column 1) =====
        local formatGroup = GUI:CreateSettingsGroup(self.child, 280)
        formatGroup:AddWidget(GUI:CreateHeader(self.child, L["Text Format"]), 40)
        
        local formatOptions = {
            ["GROUP_NUM"] = L["Group 1"],
            ["SHORT"] = L["G1"],
            ["NUM_ONLY"] = L["1"],
            ["ROMAN"] = L["I, II, III..."],
        }
        formatGroup:AddWidget(GUI:CreateDropdown(self.child, L["Label Format"], formatOptions, db, "groupLabelFormat", UpdateLabels), 55)
        formatGroup.hideOn = HideGroupLabelOptions
        formatGroup.disableChildrenOn = DisableGroupLabelOptions
        Add(formatGroup, nil, 2)
        
        -- ===== FONT GROUP (Column 1) =====
        local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontGroup:AddWidget(GUI:CreateHeader(self.child, L["Font Settings"]), 40)
        fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "groupLabelFont", UpdateLabels), 55)
        fontGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 8, 24, 1, db, "groupLabelFontSize", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)
        
        fontGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "groupLabelOutline", UpdateLabels), 55)
        fontGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "groupLabelOutline", UpdateLabels), 30)
        fontGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Label Color"], db, "groupLabelColor", true, UpdateLabels, function() DF:LightweightUpdateGroupLabelColor() end, true), 35)
        fontGroup.hideOn = HideGroupLabelOptions
        fontGroup.disableChildrenOn = DisableGroupLabelOptions
        Add(fontGroup, nil, 2)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        
        local positionOptions = {
            ["START"] = L["Start of Group"],
            ["CENTER"] = L["Center of Group"],
            ["END"] = L["End of Group"],
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Label Position"], positionOptions, db, "groupLabelPosition", UpdateLabels), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "groupLabelOffsetX", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "groupLabelOffsetY", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)
        positionGroup:AddWidget(GUI:CreateLabel(self.child, L["Start: Above/left of groups.\nCenter: Middle of the group.\nEnd: Below/right of groups."], 250), 50)
        positionGroup.hideOn = HideGroupLabelOptions
        positionGroup.disableChildrenOn = DisableGroupLabelOptions
        Add(positionGroup, nil, 1)
        
        -- Party mode message
        local partyMsg = Add(GUI:CreateLabel(self.child, L["Group labels are only available for raid frames.\n\nSwitch to Raid mode using the toggle at the top\nof the settings panel to configure group labels."], 400), 80, "both")
        partyMsg.hideOn = function() return GUI.SelectedMode == "raid" end
        
        -- Flat mode message
        local flatMsg = Add(GUI:CreateNote(self.child, L["Group labels are not available in Flat Grid layout.\n\nEnable 'Use Group-Based Layout' in Frame settings\nto use group labels."], {tone = "caution", width = 400}), 80, "both")
        flatMsg.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end
    end)
    
    -- General > Pinned Frames
    local pagePinnedFrames = CreateSubTab("general", "general_pinnedframes", L["Pinned Frames"])
    BuildPage(pagePinnedFrames, function(self, db, Add, AddSpace, AddSyncPoint)
        Add(CreateCopyButton(self.child, {"pinnedFrames"}, L["Pinned Frames"], "general_pinnedframes"), 25, 2)
        -- Constants — mirror the runtime cap so the editor builds exactly as many
        -- tab buttons as the backend allows (sets beyond the current count are hidden).
        local HIGHLIGHT_MAX_SETS = (DF.PinnedFrames and DF.PinnedFrames.MAX_SETS) or 5
        
        -- Initialize pinnedFrames in db if needed
        if not db.pinnedFrames then
            db.pinnedFrames = {
                disableInPvP = true,  -- mode-level: dormant in arena/battlegrounds
                sets = {
                    [1] = {
                        enabled = false, name = "Pinned 1", players = {},
                        growDirection = "HORIZONTAL", unitsPerRow = 5,
                        horizontalSpacing = 2, verticalSpacing = 2, scale = 1.0,
                        position = { point = "CENTER", x = 0, y = 200 },
                        showLabel = false,
                        autoAddTanks = false, autoAddHealers = false, autoAddDPS = false,
                        keepOfflinePlayers = false,
                    },
                    [2] = {
                        enabled = false, name = "Pinned 2", players = {},
                        growDirection = "HORIZONTAL", unitsPerRow = 5,
                        horizontalSpacing = 2, verticalSpacing = 2, scale = 1.0,
                        position = { point = "CENTER", x = 0, y = -200 },
                        showLabel = false,
                        autoAddTanks = false, autoAddHealers = false, autoAddDPS = false,
                        keepOfflinePlayers = false,
                    },
                },
            }
        end
        
        -- Migration: mode-level disableInPvP (existing profiles predate it). nil is
        -- treated as true by the runtime gate, but seed it so the toggle reads right.
        if db.pinnedFrames.disableInPvP == nil then db.pinnedFrames.disableInPvP = true end

        -- Migration: add new options to existing sets
        for i = 1, #db.pinnedFrames.sets do
            local set = db.pinnedFrames.sets[i]
            if set then
                if set.autoAddTanks == nil then set.autoAddTanks = false end
                if set.autoAddHealers == nil then set.autoAddHealers = false end
                if set.autoAddDPS == nil then set.autoAddDPS = false end
                -- Match Config's default (false). Post-fix, manual pins always
                -- persist (CleanOfflinePlayers spares manualPlayers); this toggle
                -- only keeps AUTO-added members after they go offline / leave.
                if set.keepOfflinePlayers == nil then set.keepOfflinePlayers = false end
                if set.columnAnchor == nil then set.columnAnchor = "START" end
                if set.frameAnchor == nil then set.frameAnchor = "START" end
                -- CENTER anchor was dropped (never truly centred the frames; it
                -- rendered as START). Normalise so the dropdown has a valid value.
                if set.columnAnchor == "CENTER" then set.columnAnchor = "START" end
                if set.frameAnchor == "CENTER" then set.frameAnchor = "START" end
                -- set.locked retired (global lock only); strip the dead field.
                set.locked = nil
                if set.showLabel == nil then set.showLabel = false end
                if set.players == nil then set.players = {} end
                if set.manualPlayers == nil then set.manualPlayers = {} end
                if set.frameType == nil then set.frameType = "player" end
                if set.testCount == nil then set.testCount = 3 end
            end
        end
        
        -- Current active tab (persist across page refreshes so switching tabs
        -- between sets with different frameTypes — which calls RefreshCurrentPage —
        -- doesn't snap back to tab 1)
        pagePinnedFrames.persistedTab = pagePinnedFrames.persistedTab or 1
        -- Clamp into the live set count — a set may have been removed since this
        -- was last persisted (or in the other mode), so never address a nil set.
        local setCount = #db.pinnedFrames.sets
        if pagePinnedFrames.persistedTab > setCount then pagePinnedFrames.persistedTab = setCount end
        if pagePinnedFrames.persistedTab < 1 then pagePinnedFrames.persistedTab = 1 end
        local activeHighlightTab = pagePinnedFrames.persistedTab
        -- Sub-tab within a set's editor:
        --   "setup"      = Settings + Frame Type   (always present)
        --   "appearance" = Frame Style + Layout    (always present)
        --   "members"    = Unit Selection + Auto-Populate (player sets only)
        -- Persisted across page rebuilds; defaults to Setup. Clamped below so a
        -- persisted "members" never sticks on a boss set (which has no Members tab).
        pagePinnedFrames.persistedSubTab = pagePinnedFrames.persistedSubTab or "setup"
        local activeSubTab = pagePinnedFrames.persistedSubTab
        local tabButtons = {}
        local controlsToRefresh = {}
        -- Forward refs assigned in the tab-strip build below; RefreshTabs reads them.
        local tabContainer, addSetBtn, setMeta

        -- Invalidate + rebuild the pinned page (after add/remove the whole editor
        -- must re-render with the new tab count + the active set's widgets).
        local function RebuildPinnedPage()
            if GUI.InvalidatePage then GUI:InvalidatePage(GUI.CurrentPageName) end
            if GUI.RefreshCurrentPage then GUI.RefreshCurrentPage() end
        end

        local function DoAddSet()
            if not DF.PinnedFrames then return end
            -- Target the mode currently being edited (party/raid are independent).
            local newIndex = DF.PinnedFrames:AddSet(GUI.SelectedMode)
            if newIndex then
                pagePinnedFrames.persistedTab = newIndex  -- jump to the new set
                RebuildPinnedPage()
            end
        end

        local function DoRemoveSet(idx)
            if not DF.PinnedFrames then return end
            -- Capture the edited mode at click time (robust if the GUI mode changes
            -- while the confirm popup is open). Party/raid set lists are independent.
            -- The closure replaces what used to travel as the StaticPopup `data`
            -- payload, which is the field whose behaviour varies across clients.
            local mode = GUI.SelectedMode
            DF:ShowPopupAlert({
                title   = L["Remove Pinned Set"],
                message = L["Remove this pinned set? Its members and settings will be lost."],
                buttons = {
                    {
                        label = L["Remove"],
                        onClick = function()
                            if DF.PinnedFrames:RemoveSet(idx, mode) then
                                if pagePinnedFrames.persistedTab > 1 then
                                    pagePinnedFrames.persistedTab = pagePinnedFrames.persistedTab - 1
                                end
                                RebuildPinnedPage()
                            end
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end

        local function GetCurrentSet()
            return db.pinnedFrames.sets[activeHighlightTab]
        end

        local function IsCurrentBossMode()
            local s = GetCurrentSet()
            return s and s.frameType == "friendlyBoss"
        end

        -- A pinned set that is not enabled shows ONLY its Enable toggle; everything
        -- else (the other Setup controls, Frame Type, and the Appearance/Members
        -- tabs) is hidden until the set is enabled.
        local function PinnedSetDisabled()
            local s = GetCurrentSet()
            return not (s and s.enabled)
        end

        -- Forward-declared: the set-tab OnClick (defined below, before this is
        -- assigned) re-runs it when you switch sets so the new set's enabled state
        -- re-drives the sub-tab visibility.
        local RefreshSubTabs

        local function RefreshControls()
            for _, ctrl in ipairs(controlsToRefresh) do
                if ctrl.Refresh then ctrl:Refresh() end
            end
        end
        
        -- Tab metrics, shared by RefreshTabs (width) and tab creation (label inset):
        -- the label must clear the status pip on the left and the × on the right.
        local TAB_LABEL_LEFT, TAB_LABEL_RIGHT = 22, 24
        local TAB_MIN_W, TAB_MAX_W = 96, 160
        local function RefreshTabs()
            local count = #db.pinnedFrames.sets
            -- Adaptive tab width: share the strip so a couple of sets get roomy
            -- tabs, clamped 120-160 so four still fit. Reserve room for the meter
            -- (right) and the + Add button (shown when below the cap). Use the
            -- fixed design width (NOT GetWidth) so the width is deterministic and
            -- can't jump on a page rebuild where GetWidth() isn't settled yet.
            local TAB_GAP = 4  -- small gap so the (now filled) cells read as distinct tabs
            -- Lay out against the container's CURRENT width so the strip adapts when
            -- the addon frame is resized narrow (fall back to the design width until
            -- the first layout pass settles GetWidth). Re-flows via OnSizeChanged.
            local cw = tabContainer:GetWidth() or 560
            if cw < 100 then cw = 560 end
            local stripW = cw - 84
            if count < HIGHLIGHT_MAX_SETS then stripW = stripW - 70 end
            -- Per-tab cap from the even share so the whole strip still fits when the
            -- window is narrow; tabs otherwise HUG their label (see naturalW below)
            -- rather than every tab stretching to a fixed width.
            local maxPerTab = math.min(TAB_MAX_W, math.floor((stripW - (count - 1) * TAB_GAP) / math.max(count, 1)))
            if maxPerTab < TAB_MIN_W then maxPerTab = TAB_MIN_W end

            local x = 0  -- running left offset; tabs are no longer uniform-width
            for i, tab in ipairs(tabButtons) do
                local set = db.pinnedFrames.sets[i]
                if not set then
                    -- Tab button beyond the current set count — hide it.
                    tab:Hide()
                else
                    tab:Show()
                    local isActive = (i == activeHighlightTab)
                    tab:SetActive(isActive)  -- underline + accent/dim label

                    -- Build the label first so the tab can be sized to it.
                    local displayName = set.name
                    if displayName == L["Pinned"] .. " " .. i or displayName == "" then displayName = L["Pinned"] .. " " .. i end
                    -- Show the pinned member count on the tab (player sets only — boss
                    -- sets auto-track boss1-8 and have no member list).
                    if set.frameType ~= "friendlyBoss" then
                        displayName = displayName .. "  (" .. #(set.players or {}) .. ")"
                    end
                    tab.text:SetText(displayName)

                    -- Hug the label (clamped): short names get a tight tab, long names
                    -- truncate at the cap instead of every tab being max width.
                    local naturalW = math.ceil(tab.text:GetStringWidth()) + TAB_LABEL_LEFT + TAB_LABEL_RIGHT
                    local tabW = math.max(TAB_MIN_W, math.min(maxPerTab, naturalW))
                    tab:SetWidth(tabW)
                    tab:SetPoint("LEFT", tabContainer, "LEFT", x, 0)
                    x = x + tabW + TAB_GAP

                    -- On/off pip, independent of the selected-tab highlight above.
                    if tab.statusDot then
                        if set.enabled then
                            tab.statusDot:SetVertexColor(0.30, 0.82, 0.38)  -- green = enabled
                        else
                            tab.statusDot:SetVertexColor(0.32, 0.32, 0.32)  -- grey = disabled
                        end
                    end
                    -- Remove (×) only on the active tab, and only when more than one
                    -- set exists (the last set can't be removed). Keeps the strip clean.
                    if tab.removeBtn then
                        if isActive and count > 1 then tab.removeBtn:Show() else tab.removeBtn:Hide() end
                    end
                end
            end
            -- "+ Add set" sits just after the last set; hidden at the cap.
            if addSetBtn then
                if count < HIGHLIGHT_MAX_SETS then
                    addSetBtn:ClearAllPoints()
                    addSetBtn:SetPoint("LEFT", tabContainer, "LEFT", x + 4, 0)
                    addSetBtn:Show()
                else
                    addSetBtn:Hide()
                end
            end
            -- Count + active-set meter (each enabled set is a live secure header).
            if setMeta then
                local active = 0
                for _, s in ipairs(db.pinnedFrames.sets) do if s.enabled then active = active + 1 end end
                setMeta:SetText(count .. "/" .. HIGHLIGHT_MAX_SETS .. "   " .. active .. " " .. L["active"])
                if active >= 4 then setMeta:SetTextColor(0.95, 0.7, 0.2) else setMeta:SetTextColor(0.45, 0.45, 0.45) end
            end
        end
        
        -- ===== HEADER GROUP (full width) =====
        local headerGroup = GUI:CreateSettingsGroup(self.child, 560)
        headerGroup:AddWidget(GUI:CreateHeader(self.child, L["Pinned Frames"]), 40)
        -- Auto-size the description's slot to the actual wrapped text height so the
        -- box hugs the text at every width (no fixed bottom padding, no truncation).
        -- GetStringHeight returns a stale single-line value right after a width
        -- change, so we measure on a DEFERRED frame (OnSizeChanged -> C_Timer) once
        -- the FontString has re-wrapped, then update the group's slot height and
        -- bubble a relayout up to the page. Mirrors GUI:CreateInfoBanner.
        local pinnedDescLabel = GUI:CreateLabel(self.child, L["Create separate frame groups to pin specific players like tanks, healers, or key raid members, or to track NPC frames. Add players using the Members tab."], 530)
        do
            local descFS
            for _, r in ipairs({ pinnedDescLabel:GetRegions() }) do
                if r.GetStringHeight then descFS = r break end
            end
            local applying, lastW = false, nil
            local function ApplyDescHeight()
                if applying or not descFS or not pinnedDescLabel:IsVisible() then return end
                local g = pinnedDescLabel.settingsGroup
                if not g then return end
                local desired = math.ceil(descFS:GetStringHeight() or 18) + 6
                for _, entry in ipairs(g.groupChildren) do
                    if entry.widget == pinnedDescLabel then
                        if entry.height ~= desired then
                            applying = true
                            entry.height = desired
                            g:LayoutChildren()
                            local p = g:GetParent()  -- bubble so the page's column layout sees the new height
                            while p do
                                if type(p.RefreshStates) == "function" and p.children then p:RefreshStates() break end
                                p = p:GetParent()
                            end
                            applying = false
                        end
                        break
                    end
                end
            end
            local function ScheduleApply()
                if C_Timer and C_Timer.After then C_Timer.After(0, ApplyDescHeight) else ApplyDescHeight() end
            end
            pinnedDescLabel:SetScript("OnSizeChanged", function(_, w)
                if w == lastW then return end  -- only width changes affect wrap height
                lastW = w
                ScheduleApply()
            end)
            -- Re-measure when the page surfaces (GetStringHeight is unreliable while
            -- hidden) and once on build in case the width never changes.
            pinnedDescLabel:SetScript("OnShow", function() lastW = nil ScheduleApply() end)
            ScheduleApply()
        end
        -- Initial slot fits 2 lines; the deferred measure grows/shrinks it to fit.
        headerGroup:AddWidget(pinnedDescLabel, 34)
        Add(headerGroup, nil, "both")
        
        -- Tab container
        tabContainer = CreateFrame("Frame", nil, self.child)
        tabContainer:SetSize(560, 32)
        Add(tabContainer, 32, "both")

        -- Baseline track running under the whole tab strip (at the tabs' bottom
        -- edge). The active tab's accent underline sits on this, giving the
        -- AD-style tab-bar effect as you switch between tabs.
        local tabBaseline = tabContainer:CreateTexture(nil, "ARTWORK")
        tabBaseline:SetTexture("Interface\\Buttons\\WHITE8x8")
        tabBaseline:SetHeight(1)
        tabBaseline:SetPoint("BOTTOMLEFT", tabContainer, "BOTTOMLEFT", 0, 1)
        tabBaseline:SetPoint("BOTTOMRIGHT", tabContainer, "BOTTOMRIGHT", 0, 1)
        local tabBaseClr = (GUI.Colors and GUI.Colors.border) or { r = 0.25, g = 0.25, b = 0.25 }
        tabBaseline:SetColorTexture(tabBaseClr.r, tabBaseClr.g, tabBaseClr.b, 0.5)

        -- Re-flow the strip when the addon frame is resized so the tabs share the
        -- current width instead of overflowing into the meter. RefreshTabs is
        -- nil-guarded for the buttons it touches, so an early fire is harmless.
        tabContainer:SetScript("OnSizeChanged", function() RefreshTabs() end)

        for i = 1, HIGHLIGHT_MAX_SETS do
            local tab = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
            tab:SetSize(120, 30)
            tab:SetPoint("LEFT", tabContainer, "LEFT", (i - 1) * 120, 0)
            -- Underline tab on the shared styler; RefreshTabs drives SetActive.
            GUI:StyleButton(tab, { tab = true, text = L["Pinned"] .. " " .. i, font = "DFFontHighlight" })
            tab.text = tab.Text  -- RefreshTabs sets the dynamic name (with count) here
            -- Pin the label between the status pip (left) and the × (right) and
            -- ellipsis-truncate, so a long name can't bleed into the next
            -- (now edge-to-edge) tab and never overlaps the pip/×.
            tab.text:ClearAllPoints()
            tab.text:SetPoint("LEFT", tab, "LEFT", TAB_LABEL_LEFT, 0)
            tab.text:SetPoint("RIGHT", tab, "RIGHT", -TAB_LABEL_RIGHT, 0)
            tab.text:SetJustifyH("CENTER")
            tab.text:SetWordWrap(false)
            -- Status pip on the left: green = set enabled, dim grey = disabled.
            -- Independent of the active-tab highlight (border + text colour), so a
            -- set's on/off state is visible whether or not it's the selected tab.
            tab.statusDot = tab:CreateTexture(nil, "OVERLAY")
            tab.statusDot:SetTexture("Interface\\Buttons\\WHITE8x8")
            tab.statusDot:SetSize(7, 7)
            tab.statusDot:SetPoint("LEFT", tab, "LEFT", 8, 0)
            -- Remove (×) button on the right — shown by RefreshTabs only on the
            -- active tab when more than one set exists. Confirms before removing.
            tab.removeBtn = GUI:CreateCloseButton(tab, { size = 16, onClick = function() DoRemoveSet(i) end })
            tab.removeBtn:SetPoint("RIGHT", tab, "RIGHT", -4, 0)
            tab.removeBtn:Hide()
            tab:SetScript("OnClick", function()
                local oldSet = GetCurrentSet()
                local oldType = oldSet and oldSet.frameType
                activeHighlightTab = i
                pagePinnedFrames.persistedTab = i
                local newSet = GetCurrentSet()
                local newType = newSet and newSet.frameType
                RefreshTabs()
                if oldType ~= newType and GUI.RefreshCurrentPage then
                    -- Frame type differs between tabs — invalidate cache so the page
                    -- rebuilds with the correct set of widgets for the new frame type.
                    if GUI.InvalidatePage then GUI:InvalidatePage(GUI.CurrentPageName) end
                    GUI.RefreshCurrentPage()
                else
                    RefreshControls()
                    -- The newly-selected set may differ in enabled state, so re-run the
                    -- disabled-gating: sub-tab visibility + per-control hideOn reflow.
                    if RefreshSubTabs then RefreshSubTabs() end
                    self:RefreshStates()
                    if GUI.RefreshAllOverrideIndicators then GUI.RefreshAllOverrideIndicators() end
                end
            end)
            tabButtons[i] = tab
        end

        -- "+ Add set" button — RefreshTabs positions it after the last set and
        -- hides it at the cap. Adds a (disabled) set to every mode + jumps to it.
        addSetBtn = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
        addSetBtn:SetSize(64, 28)
        -- Ghost action: a faint cell (matching the tabs) with an accent "+ Add"
        -- that brightens on hover — consistent with the strip, quiet add action.
        GUI:StyleButton(addSetBtn, { ghost = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 14 }, text = L["Add"], font = "DFFontHighlight" })
        addSetBtn:SetScript("OnClick", DoAddSet)

        -- Count / active-set meter, right of the strip (each enabled set is a live
        -- secure header — surfacing the active count makes the perf cost visible).
        setMeta = tabContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        setMeta:SetPoint("RIGHT", tabContainer, "RIGHT", -2, 0)
        setMeta:SetTextColor(0.45, 0.45, 0.45)

        RefreshTabs()

        -- ===== SUB-TABS (Setup / Appearance / Members) =====
        -- Splits the set editor so each concern has its own tab and no single page
        -- is a long scroll. Switching just toggles group visibility via hideOn + a
        -- RefreshStates() reflow (no page rebuild). The Members tab only exists for
        -- player sets (boss sets auto-track boss1-8 and have no roster); the page
        -- rebuilds on a frame-type change, so this list is rebuilt with it.
        if activeSubTab == "members" and IsCurrentBossMode() then activeSubTab = "setup" end
        local subTabDefs = { { key = "setup", label = L["Setup"] }, { key = "appearance", label = L["Appearance"] } }
        if not IsCurrentBossMode() then
            table.insert(subTabDefs, { key = "members", label = L["Members"] })
        end
        local subTabButtons = {}
        local subTabContainer = CreateFrame("Frame", nil, self.child)
        subTabContainer:SetSize(460, 24)
        RefreshSubTabs = function()
            -- A disabled set snaps selection to Setup (its only live content is the
            -- Enable toggle; the Setup controls + Frame Type grey in place).
            local disabled = PinnedSetDisabled()
            if disabled then activeSubTab = "setup" end
            local x = 0
            for _, b in ipairs(subTabButtons) do
                b:Show()
                b:ClearAllPoints()
                b:SetPoint("LEFT", subTabContainer, "LEFT", x, 0)
                x = x + b:GetWidth() + 6
                b:SetActive(b.key == activeSubTab)  -- filled toggle (white label both states)
                -- While the set is off, grey + deactivate the non-Setup tabs: dim the
                -- whole button (SetAlpha) and disable its mouse (EnableMouse false) so
                -- there's NO hover wash and no clicks; Setup stays live. We use
                -- SetAlpha+EnableMouse rather than StyleButton:SetDisabled, which fought
                -- the hover wash and rendered a solid bright fill on hover.
                local greyTab = disabled and b.key ~= "setup"
                b:EnableMouse(not greyTab)
                b:SetAlpha(greyTab and 0.4 or 1)
            end
        end
        local subX = 0
        for i, def in ipairs(subTabDefs) do
            local b = CreateFrame("Button", nil, subTabContainer, "BackdropTemplate")
            b.key = def.key
            b:SetHeight(22)
            -- Filled toggle on the shared styler; RefreshSubTabs drives SetActive.
            GUI:StyleButton(b, { text = def.label })
            -- Content-sized + flowed so this secondary row stays compact (clearly
            -- subordinate to the underline tabs above), like AD's chips.
            b:SetWidth(math.ceil(b.Text:GetStringWidth()) + 24)
            b:SetPoint("LEFT", subTabContainer, "LEFT", subX, 0)
            subX = subX + b:GetWidth() + 6
            b:SetScript("OnClick", function(self)
                if self.dfDisabled then return end  -- greyed tab (set disabled) — ignore clicks
                activeSubTab = def.key
                pagePinnedFrames.persistedSubTab = def.key
                RefreshSubTabs()
                pagePinnedFrames:RefreshStates()  -- reflow: hideOn predicates re-evaluate against activeSubTab
            end)
            subTabButtons[i] = b
        end
        RefreshSubTabs()
        AddSpace(6, "both")  -- breathing room between the tab strip and the sub-row
        Add(subTabContainer, 26, "both")

        AddSpace(GUI.Space.section, "both")

        -- Helper to get the pinned override key for the current active tab
        local function GetPinnedKey(dbKey)
            return "pinned." .. activeHighlightTab .. "." .. dbKey
        end
        
        -- Add override indicators (star, reset, global text) to a pinned frame control
        local function AddPinnedOverrideIndicators(container, lbl, dbKey, onReset)
            local AutoProfilesUI = DF.AutoProfilesUI
            if not AutoProfilesUI then return end
            
            -- Reset button (red, icon-only) + override marker (dot) — shared helpers.
            local resetBtn = GUI:CreateOverrideResetButton(container, {
                tooltip = L["Reset to Global"],
                tooltipDesc = L["Reset this setting to its global value."],
                onClick = function() if onReset then onReset() end end,
            })
            resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
            container.overrideResetBtn = resetBtn

            local starFrame = GUI:CreateOverrideMarker(container)
            starFrame:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
            container.overrideStar = starFrame
            
            -- Global value text
            local globalText = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            globalText:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
            globalText:SetTextColor(0.4, 0.4, 0.4)
            globalText:Hide()
            container.overrideGlobalText = globalText
            
            -- Checkmark icon
            local checkIcon = container:CreateTexture(nil, "OVERLAY")
            checkIcon:SetSize(8, 8)
            checkIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
            checkIcon:SetVertexColor(0.3, 0.7, 0.3)
            checkIcon:Hide()
            container.overrideCheckIcon = checkIcon
            
            container.UpdateOverrideIndicators = function(self)
                -- Only the per-set `enabled` flag is layout-overridable now; every
                -- other pinned setting is global/independent of auto layouts, so it
                -- shows no override UI at all (no star, reset, or "Global:" text).
                if not (DF.AutoProfilesUI and DF.AutoProfilesUI.IsPinnedSettingOverridable
                        and DF.AutoProfilesUI:IsPinnedSettingOverridable(dbKey)) then
                    self.overrideStar:Hide(); self.overrideResetBtn:Hide()
                    self.overrideGlobalText:Hide(); self.overrideCheckIcon:Hide()
                    return
                end
                -- Debug mode
                if GUI.IsOverrideDebugMode and GUI.IsOverrideDebugMode() then
                    self.overrideStar:Show()
                    self.overrideResetBtn:Show()
                    self.overrideGlobalText:SetText("(debug)")
                    self.overrideGlobalText:SetTextColor(1, 0.8, 0.2)
                    self.overrideGlobalText:Show()
                    self.overrideCheckIcon:Hide()
                    return
                end
                
                -- Only show in raid mode while editing
                if not GUI or GUI.SelectedMode ~= "raid" then
                    self.overrideStar:Hide(); self.overrideResetBtn:Hide()
                    self.overrideGlobalText:Hide(); self.overrideCheckIcon:Hide()
                    return
                end
                
                local isEditing = AutoProfilesUI and AutoProfilesUI:IsEditing()
                local pinnedKey = GetPinnedKey(dbKey)
                local isRuntimeOverridden = AutoProfilesUI and AutoProfilesUI:IsOverriddenByRuntime(pinnedKey)

                -- Hide everything if not editing AND not runtime-overridden
                if not isEditing and not isRuntimeOverridden then
                    self.overrideStar:Hide(); self.overrideResetBtn:Hide()
                    self.overrideGlobalText:Hide(); self.overrideCheckIcon:Hide()
                    return
                end

                -- Runtime override mode: show star + global value, no reset button
                if isRuntimeOverridden and not isEditing then
                    self.overrideStar.tooltipText = L["Override active"]
                    self.overrideStar.tooltipSubText = L["This setting is being overridden by the active auto layout profile. To change it, edit the profile in the Auto Layouts tab."]
                    self.overrideStar:Show()
                    self.overrideResetBtn:Hide()
                    self.overrideCheckIcon:Hide()

                    local globalValue = AutoProfilesUI:GetRuntimeGlobalValue(pinnedKey)
                    local globalDisplay
                    if type(globalValue) == "boolean" then
                        globalDisplay = globalValue and L["Yes"] or L["No"]
                    elseif type(globalValue) == "number" then
                        if globalValue == math.floor(globalValue) then
                            globalDisplay = tostring(globalValue)
                        else
                            globalDisplay = string.format("%.2f", globalValue)
                        end
                    elseif type(globalValue) == "table" then
                        globalDisplay = "..."
                    else
                        globalDisplay = tostring(globalValue or "None")
                    end

                    self.overrideGlobalText:SetText(L["Global: "] .. globalDisplay)
                    self.overrideGlobalText:SetTextColor(0.5, 0.5, 0.5)
                    self.overrideGlobalText:Show()
                    return
                end

                -- Editing mode: existing behavior
                local isOverridden = AutoProfilesUI:IsSettingOverridden(pinnedKey)
                local globalValue = AutoProfilesUI:GetGlobalValue(pinnedKey)

                if isOverridden then
                    self.overrideStar.tooltipText = L["Override active"]
                    self.overrideStar.tooltipSubText = L["This setting differs from the global profile value. Click the reset button to revert."]
                    self.overrideStar:Show()
                    self.overrideResetBtn:Show()
                else
                    self.overrideStar:Hide()
                    self.overrideResetBtn:Hide()
                end

                -- Format global value for display
                local globalDisplay
                if type(globalValue) == "boolean" then
                    globalDisplay = globalValue and L["Yes"] or L["No"]
                elseif type(globalValue) == "number" then
                    if globalValue == math.floor(globalValue) then
                        globalDisplay = tostring(globalValue)
                    else
                        globalDisplay = string.format("%.2f", globalValue)
                    end
                elseif type(globalValue) == "table" then
                    globalDisplay = "..."
                else
                    globalDisplay = tostring(globalValue or "None")
                end

                -- Show global text with check/star positioning
                if isOverridden then
                    self.overrideGlobalText:SetText(L["Global: "] .. globalDisplay)
                    self.overrideGlobalText:SetTextColor(0.4, 0.4, 0.4)
                    self.overrideGlobalText:Show()
                    self.overrideCheckIcon:Hide()
                else
                    self.overrideGlobalText:SetText(L["Global: "] .. globalDisplay)
                    self.overrideGlobalText:SetTextColor(0.3, 0.7, 0.3)
                    self.overrideGlobalText:Show()
                    self.overrideCheckIcon:SetPoint("RIGHT", self.overrideGlobalText, "LEFT", -2, 0)
                    self.overrideCheckIcon:Show()
                end
            end
            
            -- Register for global refresh
            if GUI.RegisterOverrideWidget then
                GUI.RegisterOverrideWidget(container)
            end
        end
        
        -- Helper function to create refreshable checkbox
        local function CreateRefreshableCheckbox(parent, label, dbKey, callback, tooltip)
            local container = CreateFrame("Frame", nil, parent)
            container:SetSize(250, 24)
            local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
            cb:SetPoint("LEFT", 0, 0)
            GUI:StyleCheckButton(cb, { themeRoot = parent })
            local txt = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            txt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
            txt:SetText(label)
            txt:SetTextColor(0.8, 0.8, 0.8)
            if tooltip then
                cb:SetScript("OnEnter", function(s)
                    GUI:ShowTooltip(s, {
                        title = label,
                        lines = { tooltip },
                    })
                end)
                cb:SetScript("OnLeave", function() GUI:HideTooltip() end)
            end
            cb:SetScript("OnClick", function(s)
                local val = s:GetChecked()
                -- Runtime override protection
                if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
                   and DF.AutoProfilesUI:HandleRuntimeWrite(GetPinnedKey(dbKey), val) then
                    if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
                    return
                end
                GetCurrentSet()[dbKey] = val
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                    DF.AutoProfilesUI:SetProfileSetting(GetPinnedKey(dbKey), val)
                end
                if callback then callback(GetCurrentSet()) end
                DF:UpdateAll()
                if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
            end)
            container.Refresh = function()
                cb:SetChecked(GetCurrentSet()[dbKey])
                -- Optional disabled state: when container.enabledWhen() is false the
                -- checkbox is greyed and can't be toggled (used where one toggle is
                -- only meaningful while another option is in a particular state).
                if container.enabledWhen then
                    if container.enabledWhen() then
                        cb:Enable()
                        txt:SetTextColor(0.8, 0.8, 0.8)
                        cb.Check:SetVertexColor(tc.r, tc.g, tc.b)
                    else
                        cb:Disable()
                        txt:SetTextColor(0.4, 0.4, 0.4)
                        cb.Check:SetVertexColor(0.4, 0.4, 0.4)
                    end
                end
                if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
            end
            
            -- Override indicators with reset
            AddPinnedOverrideIndicators(container, txt, dbKey, function()
                local AutoProfilesUI = DF.AutoProfilesUI
                if AutoProfilesUI then
                    AutoProfilesUI:ResetProfileSetting(GetPinnedKey(dbKey))
                    cb:SetChecked(GetCurrentSet()[dbKey])
                    if callback then callback(GetCurrentSet()) end
                    DF:UpdateAll()
                    if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
                end
            end)
            
            -- Group-gate hook: lets settingsGroup.disableChildrenOn grey this checkbox
            -- in place (dim the box + label, block toggling) without hiding it.
            container.SetEnabled = function(_, enabled)
                if enabled then cb:Enable() else cb:Disable() end
                txt:SetTextColor(0.8, 0.8, 0.8)
                txt:SetAlpha(enabled and 1 or 0.4)
                cb:SetAlpha(enabled and 1 or 0.4)
            end

            container.Refresh()
            table.insert(controlsToRefresh, container)
            return container
        end

        -- Helper function to create refreshable slider
        --
        -- Delegates the slider chrome/value plumbing to the shared GUI:CreateSlider
        -- builder (theme colour). The pinned value lives in GetCurrentSet()[dbKey],
        -- so we drive CreateSlider via customGet/customSet (dbKey passed as nil so
        -- CreateSlider's own raw-key runtime/profile/override paths stay off — the
        -- pinned system keys off the PREFIXED GetPinnedKey(dbKey) instead, handled
        -- here in customSet + AddPinnedOverrideIndicators below).
        local function CreateRefreshableSlider(parent, label, minVal, maxVal, step, dbKey, callback)
            local container
            local function customGet()
                return GetCurrentSet()[dbKey] or minVal
            end
            local function customSet(value)
                -- Runtime override protection (raid auto-layout): redirect the write
                -- to the active profile baseline and skip the set write entirely.
                if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
                   and DF.AutoProfilesUI:HandleRuntimeWrite(GetPinnedKey(dbKey), value) then
                    if container and container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
                    return
                end
                GetCurrentSet()[dbKey] = value
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                    DF.AutoProfilesUI:SetProfileSetting(GetPinnedKey(dbKey), value)
                end
                if container and container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
            end
            container = GUI:CreateSlider(parent, label, minVal, maxVal, step, nil, nil, callback, nil, nil, customGet, customSet)

            -- Refresh: re-read the set's value into the slider (used on page rebuild
            -- and Match-mode changes). The `updating`/suppressCallback guard inside
            -- CreateSlider's UpdateValue means this programmatic SetValue does not
            -- re-fire the user callback or re-write the db.
            container.Refresh = function()
                container.slider:SetValue(GetCurrentSet()[dbKey] or minVal)
                if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
            end
            container.SetValue = function(_, val)
                container.slider:SetValue(val)
            end

            -- Override indicators with reset (prefixed pinned key).
            AddPinnedOverrideIndicators(container, container.label, dbKey, function()
                local AutoProfilesUI = DF.AutoProfilesUI
                if AutoProfilesUI then
                    AutoProfilesUI:ResetProfileSetting(GetPinnedKey(dbKey))
                    container.slider:SetValue(GetCurrentSet()[dbKey] or minVal)
                    if callback then callback() end
                    DF:UpdateAll()
                    if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
                end
            end)

            container.Refresh()
            table.insert(controlsToRefresh, container)
            return container
        end

        -- Slider whose baseline value comes from the set's Match mode (the
        -- party/raid main-frame field `baselineKey`, e.g. "frameWidth"), with
        -- auto-layout-style override UX: changing it stores a per-set override in
        -- set[overrideKey] (e.g. "customWidth"); a gold star + reset button appear,
        -- and reset clears the override to revert to the Match value. This makes
        -- "Match sets the value, the user overrides it" read the same as a layout
        -- override. These keys are NOT auto-layout overridable, so there is no
        -- runtime/HandleRuntimeWrite path — writes go straight to the set.
        local function CreateMatchOverrideSlider(parent, label, minVal, maxVal, step, overrideKey, baselineKey, callback)
            -- Slider chrome/value plumbing delegated to GUI:CreateSlider (theme
            -- colour). dbKey is passed as nil (these keys are NOT auto-layout
            -- overridable, so CreateSlider's raw-key runtime/profile/override paths
            -- must stay off) and the value is driven via customGet/customSet, which
            -- read the EffectiveValue and store the per-set override below.
            local container

            local function MatchValue()
                local set = GetCurrentSet()
                local mode = (set and set.matchMode) or GUI.SelectedMode
                local mdb = DF:GetDB(mode)
                -- baselineKey may be a function (mdb, set) -> value, for settings
                -- whose inherited source is mode-dependent (e.g. spacing: grouped
                -- raid uses frameSpacing, flat raid uses raidFlat*Spacing).
                if type(baselineKey) == "function" then
                    return baselineKey(mdb, set) or minVal
                end
                return (mdb and mdb[baselineKey]) or minVal
            end
            -- Float-tolerant compare (half a step): fractional-step slider drags
            -- produce values like 0.5999999, so exact == against the baseline
            -- never matched and dragging Scale back to the inherited value left
            -- a stale override + star at an identical-looking number.
            local function MatchesBaseline(v)
                local m = MatchValue()
                return v ~= nil and m ~= nil and math.abs(v - m) < (step * 0.5)
            end
            local function IsOverridden()
                local set = GetCurrentSet()
                return set ~= nil and set[overrideKey] ~= nil and not MatchesBaseline(set[overrideKey])
            end
            local function EffectiveValue()
                local set = GetCurrentSet()
                return (set and set[overrideKey]) or MatchValue()
            end
            -- Store an override only when it differs from the inherited value; setting
            -- it back to the inherited value clears it (so no stale star remains).
            local function SetOverride(v)
                if MatchesBaseline(v) then GetCurrentSet()[overrideKey] = nil
                else GetCurrentSet()[overrideKey] = v end
            end
            local function FmtVal(v) return step < 1 and string.format("%.1f", v) or string.format("%d", v) end

            -- Forward-declared so customSet (below) can refresh the star/reset after
            -- each write; assigned once the indicator frames exist.
            local UpdateIndicators

            -- customGet/customSet drive the shared slider: the displayed value is the
            -- EffectiveValue (override if set, else the Match baseline) and a user
            -- edit stores/clears the per-set override. dbKey is nil so CreateSlider's
            -- raw-key runtime/profile/override machinery stays off.
            local function customGet() return EffectiveValue() end
            local function customSet(v)
                SetOverride(v)
                if UpdateIndicators then UpdateIndicators() end
            end
            container = GUI:CreateSlider(parent, label, minVal, maxVal, step, nil, nil, callback, nil, nil, customGet, customSet)

            -- Reset-to-Match button (TOPRIGHT) + gold override star to its left,
            -- mirroring AddPinnedOverrideIndicators so it reads like a layout override.
            -- Reset-to-Match (red, icon-only) + override marker (dot) — shared
            -- helpers. The marker tooltip is dynamic (shows the inherited value)
            -- so it's set below; the reset OnClick is wired further down.
            local resetBtn = GUI:CreateOverrideResetButton(container, { tooltip = L["Reset to inherited value"] })
            resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)

            local starFrame = GUI:CreateOverrideMarker(container)
            starFrame:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
            starFrame:SetScript("OnEnter", function(s)
                GUI:ShowTooltip(s, {
                    title = L["Override active"],
                    lines = { string.format(L["Inherited value: %s"], FmtVal(MatchValue())) },
                })
            end)
            starFrame:SetScript("OnLeave", function() GUI:HideTooltip() end)

            UpdateIndicators = function()
                if IsOverridden() then starFrame:Show(); resetBtn:Show() else starFrame:Hide(); resetBtn:Hide() end
            end
            -- Also exposed so CreateSlider's own handlers (drag-end etc.) refresh it.
            container.UpdateOverrideIndicators = UpdateIndicators

            -- Reset clears the per-set override and snaps the slider back to the
            -- inherited Match value. The slider's programmatic SetValue is guarded by
            -- CreateSlider's suppressCallback, so this does not re-write an override.
            resetBtn:SetScript("OnClick", function()
                GetCurrentSet()[overrideKey] = nil
                container.slider:SetValue(EffectiveValue())
                if callback then callback() end
                UpdateIndicators()
            end)

            container.Refresh = function()
                container.slider:SetValue(EffectiveValue())
                UpdateIndicators()
            end
            container.Refresh()
            table.insert(controlsToRefresh, container)
            return container
        end

        -- Helper function to create refreshable dropdown
        --
        -- Delegates the dropdown chrome/menu plumbing to the shared GUI:CreateDropdown
        -- builder (theme colour). The pinned value lives in GetCurrentSet()[dbKey],
        -- so we drive CreateDropdown via customGet/customSet (dbKey passed as nil so
        -- the builder's own raw-key runtime/profile/override paths stay off — the
        -- pinned system keys off the PREFIXED GetPinnedKey(dbKey) instead, handled
        -- here in customSet + AddPinnedOverrideIndicators below). Mirrors
        -- CreateRefreshableSlider's structure exactly.
        local function CreateRefreshableDropdown(parent, label, options, dbKey, callback)
            local container
            local function customGet()
                return GetCurrentSet()[dbKey]
            end
            local function customSet(value)
                -- Runtime override protection (raid auto-layout): redirect the write
                -- to the active profile baseline and skip the set write entirely.
                if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
                   and DF.AutoProfilesUI:HandleRuntimeWrite(GetPinnedKey(dbKey), value) then
                    if container and container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
                    return
                end
                GetCurrentSet()[dbKey] = value
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                    DF.AutoProfilesUI:SetProfileSetting(GetPinnedKey(dbKey), value)
                end
                if container and container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
            end
            container = GUI:CreateDropdown(parent, label, options, nil, nil, callback, customGet, customSet)

            -- Refresh: re-read the set's value into the dropdown text (used on page
            -- rebuild and Match-mode changes). UpdateText reads via customGet, so it
            -- never re-writes the db or re-fires the callback.
            container.Refresh = function()
                container:UpdateText()
                if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
            end

            -- Override indicators with reset (prefixed pinned key).
            AddPinnedOverrideIndicators(container, container.label, dbKey, function()
                local AutoProfilesUI = DF.AutoProfilesUI
                if AutoProfilesUI then
                    AutoProfilesUI:ResetProfileSetting(GetPinnedKey(dbKey))
                    container:UpdateText()
                    if callback then callback() end
                    if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators() end
                end
            end)

            container.Refresh()
            table.insert(controlsToRefresh, container)
            return container
        end

        -- Per-set Aura/Text Designer preset picker. Unlike CreateRefreshableDropdown
        -- its menu is rebuilt every open (the preset library grows/shrinks as presets
        -- are created/renamed/deleted on the AD/TD pages), and the first entry,
        -- "Inherit", maps to nil — the set then follows its mode's preset via the
        -- resolver's FrameMode fallback. Preset refs are global-per-mode (never an
        -- auto-layout override), so this writes straight to the set with no star.
        -- `kind` is "aura" or "text"; `dbKey` the matching set ref.
        local function CreatePinnedPresetDropdown(parent, label, kind, dbKey, callback)
            local container
            -- Sentinel option KEY for the "Inherit" row. Stored value nil means
            -- inherit, but option tables cannot be keyed by nil, so the dropdown
            -- carries this string key and customGet/customSet translate nil<->INHERIT.
            local INHERIT = "__inherit__"

            local function InheritLabel()
                local modeName = (DF.GetModeDesignerPresetName and DF:GetModeDesignerPresetName(kind, GUI.SelectedMode))
                    or DF.DEFAULT_PRESET
                return L["Inherit"] .. " (" .. tostring(modeName) .. ")"
            end

            -- Dynamic option list, rebuilt on every open (the preset library grows/
            -- shrinks as presets are created/renamed/deleted on the AD/TD pages).
            -- _order keeps Inherit first, then the preset names in ListDesignerPresets
            -- order (DEFAULT_PRESET first, the rest sorted) — matching the old menu.
            local function BuildOptions()
                local opts = { [INHERIT] = InheritLabel() }
                local order = { INHERIT }
                for _, name in ipairs(DF:ListDesignerPresets(kind)) do
                    opts[name] = name
                    order[#order + 1] = name
                end
                opts._order = order
                return opts
            end

            -- Value get/set: nil (no per-set ref) reads as INHERIT; selecting INHERIT
            -- clears the set ref back to nil so the set follows its mode's preset.
            -- Preset refs are global-per-mode (never an auto-layout override), so this
            -- writes straight to the set with no star (no AddPinnedOverrideIndicators).
            local function customGet()
                local set = GetCurrentSet()
                local cur = set and set[dbKey]
                return cur or INHERIT
            end
            local function customSet(value)
                local set = GetCurrentSet()
                if set then set[dbKey] = (value ~= INHERIT) and value or nil end
            end

            container = GUI:CreateDropdown(parent, label, BuildOptions(), nil, nil, callback,
                customGet, customSet, { optionsFunc = BuildOptions })

            -- Refresh re-reads the set's ref into the button text (the Inherit label
            -- also re-resolves for the current mode). UpdateText reads via customGet,
            -- so it never re-writes the set or re-fires the callback.
            container.Refresh = function()
                container:UpdateText()
            end

            container.Refresh()
            table.insert(controlsToRefresh, container)
            return container
        end

        -- Helper function to update layout
        local function UpdateHighlightLayout()
            if DF.PinnedFrames then
                DF.PinnedFrames:ApplyLayoutSettings(activeHighlightTab)
                DF.PinnedFrames:ResizeContainer(activeHighlightTab)
                -- If a preview container is active for the edited mode, keep it in sync
                DF.PinnedFrames:UpdatePreviewSet(activeHighlightTab)
            end
        end
        
        -- Forward declaration for roster widget and unit selection header
        local rosterWidget
        local unitSelHeader
        
        -- Helper: sync players array to override system after auto-populate
        local function SyncPlayersOverride()
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                local players = GetCurrentSet().players
                local copy = {}
                for i, v in ipairs(players) do copy[i] = v end
                DF.AutoProfilesUI:SetProfileSetting(GetPinnedKey("players"), copy)
                if unitSelHeader and unitSelHeader.UpdateOverrideIndicators then
                    unitSelHeader:UpdateOverrideIndicators()
                end
            end
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)

        -- While editing a raid auto layout, make the decouple explicit via an info
        -- banner: only the per-set Enable flag can differ per layout; everything
        -- else is shared. Hidden unless editing a raid layout.
        local pinnedLayoutNote = GUI:CreateInfoBanner(self.child, {
            tone = "info",
            text = L["Auto layouts can only change whether pinned frames are shown (Enable). All other pinned frame settings are shared across layouts."],
        })
        pinnedLayoutNote.hideOn = function()
            return not (GUI.SelectedMode == "raid" and DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing())
        end
        settingsGroup:AddWidget(pinnedLayoutNote, pinnedLayoutNote.layoutHeight or 44)

        -- SetEnabled / SetShowLabel internally use GetSetDB → IsInRaid(),
        -- so calling them while editing the inactive mode would mutate the active
        -- mode's state. Only call them when the selected mode matches the live mode;
        -- otherwise the DB write from the checkbox itself is enough and the preview
        -- reflects the change.
        local function IsEditingActiveMode()
            local actualMode = IsInRaid() and "raid" or "party"
            return GUI.SelectedMode == actualMode
        end

        -- Refresh Test Mode frames if active — enable/lock toggles affect
        -- mover visibility and whether test frames should render at all.
        local function RefreshTestModeIfActive()
            if DF.PinnedFrames.IsTestModeActive and DF.PinnedFrames:IsTestModeActive() then
                DF.PinnedFrames:ExitTestMode()
                DF.PinnedFrames:EnterTestMode()
            end
        end

        local pinnedEnableCheck = settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Enable"], "enabled", function()
            -- Enabling/disabling a set greys/ungreys the rest of its tabs + controls.
            RefreshSubTabs()
            self:RefreshStates()
            if not DF.PinnedFrames then return end
            if IsEditingActiveMode() then
                DF.PinnedFrames:SetEnabled(activeHighlightTab, GetCurrentSet().enabled)
            end
            DF.PinnedFrames:UpdatePreviewSet(activeHighlightTab)
            RefreshTestModeIfActive()
            RefreshTabs()  -- update the on/off pip on this set's tab
        end), 28)
        -- The Enable toggle itself must stay live while its set is disabled (it's the
        -- only way back on); disableChildrenOn below greys every OTHER Setup control.
        pinnedEnableCheck.keepEnabled = true
        -- Pinned frames now lock/unlock together with the main frames (global
        -- lock), so there is no per-set Lock Position toggle. Show Label is always
        -- editable; the "Drag to Move" handle only appears while globally unlocked.
        settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Show Label"], "showLabel", function()
            if not DF.PinnedFrames then return end
            if IsEditingActiveMode() then
                DF.PinnedFrames:SetShowLabel(activeHighlightTab, GetCurrentSet().showLabel)
            end
            DF.PinnedFrames:UpdatePreviewSet(activeHighlightTab)
            RefreshTestModeIfActive()
        end), 28)

        -- Party-only: show this pinned set while solo (off by default — pinned
        -- frames highlight other group members). Raid implies a group, so hide it
        -- in raid mode.
        local soloCheck = settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Show in Solo Mode"], "showInSoloMode", function()
            if not DF.PinnedFrames then return end
            -- Re-apply visibility so the solo gate takes effect immediately.
            DF.PinnedFrames:SetEnabled(activeHighlightTab, GetCurrentSet().enabled)
            RefreshTestModeIfActive()
        end), 28)
        soloCheck.hideOn = function() return GUI.SelectedMode == "raid" end

        -- Declutter toggles: hide auras / status icons on this set's frames for a
        -- clean highlight. Re-stamp the effective DB and re-render so it applies live.
        local function RefreshPinnedDisplay()
            UpdateHighlightLayout()
            if DF.UpdateAll then DF:UpdateAll() end
            if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
            RefreshTestModeIfActive()
        end
        settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Hide Auras"], "hideAuras", RefreshPinnedDisplay), 28)
        settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Hide Status Icons"], "hideIcons", RefreshPinnedDisplay), 28)

        -- Hide from Main Frames (#78): when on, this set's members are filtered out
        -- of the main party/raid frames so they only appear in the pinned set. Re-
        -- filter the main headers on toggle (out of combat). Boss sets pin boss units,
        -- not main-frame members, so it's moot there → hidden in boss mode.
        local hideMainCheck = settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Hide from Main Frames"], "hideFromMainFrames", function()
            RefreshPinnedDisplay()
            -- Defer past CreateRefreshableCheckbox's trailing DF:UpdateAll() so the
            -- re-filter isn't stomped, then re-apply the main-frame sort directly.
            C_Timer.After(0, function()
                if DF.RefreshMainFrameSorting then DF:RefreshMainFrameSorting() end
            end)
        end, L["Hide from Main Frames Tooltip"]), 28)
        hideMainCheck.hideOn = function() return IsCurrentBossMode() end

        -- Disable in PvP (GLOBAL across both modes, not per-set): keep pinned frames
        -- dormant in all instanced PvP. Default on — pinned is a party/raid feature
        -- and the arena/BG event storm can exhaust the per-frame budget. Turning it
        -- off re-enables pinned there; the debounced RequestProcessAllSets keeps that
        -- opt-in from stampeding.
        --
        -- The runtime gate reads the CURRENT mode's pinnedFrames.disableInPvP (arena
        -- resolves to party config, battlegrounds to raid). To make one checkbox act
        -- globally — and to match the "Disable in PvP" label — the toggle writes BOTH
        -- modes in lockstep, so whichever mode the gate resolves to sees the same
        -- value. Hidden while editing a raid auto-layout (it's global, nothing
        -- layout-specific to override); outside the editor DF.db.party/.raid are the
        -- plain mode profiles, so the paired write lands on the real globals.
        local function GetDisableInPvP()
            local v = db.pinnedFrames.disableInPvP
            if v == nil then return true end  -- runtime gate treats nil as true
            return v
        end
        local function SetDisableInPvP(val)
            for _, m in ipairs({ "party", "raid" }) do
                local mdb = DF.db and DF.db[m]
                if mdb and mdb.pinnedFrames then
                    mdb.pinnedFrames.disableInPvP = val
                end
            end
        end
        local disablePvPContainer = CreateFrame("Frame", nil, self.child)
        disablePvPContainer:SetSize(250, 24)
        local dpvpCB = CreateFrame("CheckButton", nil, disablePvPContainer, "BackdropTemplate")
        dpvpCB:SetPoint("LEFT", 0, 0)
        GUI:StyleCheckButton(dpvpCB, { themeRoot = self.child })
        local dpvpTxt = disablePvPContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        dpvpTxt:SetPoint("LEFT", dpvpCB, "RIGHT", 8, 0)
        dpvpTxt:SetTextColor(0.8, 0.8, 0.8)
        dpvpCB:SetScript("OnClick", function(s)
            SetDisableInPvP(s:GetChecked() and true or false)
            -- Re-evaluate visibility for the live mode (debounced + combat-safe).
            if DF.PinnedFrames and IsEditingActiveMode() and DF.PinnedFrames.RequestProcessAllSets then
                DF.PinnedFrames:RequestProcessAllSets()
            end
        end)
        dpvpCB:SetScript("OnEnter", function(s)
            GUI:ShowTooltip(s, {
                title = L["Disable in PvP"],
                lines = {
                    L["Pinned frames are a party/raid feature. Leave on to keep them hidden in arena and battlegrounds, where the constant unit churn can hurt performance. Applies to both party and raid pinned sets."],
                },
            })
        end)
        dpvpCB:SetScript("OnLeave", function() GUI:HideTooltip() end)
        disablePvPContainer.Refresh = function()
            dpvpTxt:SetText(L["Disable in PvP"])
            dpvpCB:SetChecked(GetDisableInPvP())
        end
        -- SetEnabled shim so settingsGroup.disableChildrenOn can grey this custom
        -- container in place (dim the checkbox + label) when the set is disabled.
        disablePvPContainer.SetEnabled = function(_, enabled)
            dpvpCB:SetEnabled(enabled)
            dpvpTxt:SetTextColor(0.8, 0.8, 0.8)
            dpvpTxt:SetAlpha(enabled and 1 or 0.4)
            dpvpCB:SetAlpha(enabled and 1 or 0.4)
        end
        -- Mode-global setting: not layout-overridable, so hide it while editing a
        -- raid auto-layout (its banner already points users at the base settings).
        disablePvPContainer.hideOn = function()
            return DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing()
        end
        disablePvPContainer.Refresh()
        table.insert(controlsToRefresh, disablePvPContainer)
        settingsGroup:AddWidget(disablePvPContainer, 28)

        -- Reset Position button
        local resetPosBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        GUI:StyleButton(resetPosBtn, { width = 130, height = 22, text = L["Reset Position"] })
        -- Route the group gate's SetEnabled through StyleButton's grey path so the
        -- button dims in place (instead of native-disabling) while the set is off.
        resetPosBtn.SetEnabled = function(self, enabled) self:SetDisabled(not enabled) end
        resetPosBtn:SetScript("OnClick", function(self)
            if self.dfDisabled then return end  -- greyed (set disabled) — ignore clicks
            local set = GetCurrentSet()
            if not set or not DF.PinnedFrames then return end

            -- Reset position in the edited (selected) mode's DB
            set.position = { point = "CENTER", x = 0, y = 0 }

            -- Apply to the real container only if editing the actual mode
            local actualMode = IsInRaid() and "raid" or "party"
            if GUI.SelectedMode == actualMode then
                local container = DF.PinnedFrames.containers[activeHighlightTab]
                if container then
                    container:ClearAllPoints()
                    container:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                    DF.PinnedFrames:ApplyLayoutSettings(activeHighlightTab)
                end
            end

            -- Keep the preview in sync if one is active for the edited mode
            DF.PinnedFrames:UpdatePreviewSet(activeHighlightTab)
        end)
        settingsGroup:AddWidget(resetPosBtn, 28)

        -- Label name input
        local nameInputContainer = CreateFrame("Frame", nil, self.child)
        nameInputContainer:SetSize(250, 44)
        local nameLabel = nameInputContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        nameLabel:SetPoint("TOPLEFT", 0, 0)
        nameLabel:SetText(L["Label Name"])
        nameLabel:SetTextColor(0.8, 0.8, 0.8)
        local nameInput = CreateFrame("EditBox", nil, nameInputContainer, "BackdropTemplate")
        nameInput:SetPoint("TOPLEFT", 0, -15)
        nameInput:SetSize(220, 24)
        GUI:StyleEditBox(nameInput)
        nameInput:SetAutoFocus(false)
        nameInput:SetMaxLetters(30)
        nameInput:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        nameInput:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
        nameInput:SetScript("OnEditFocusLost", function(s)
            GetCurrentSet().name = s:GetText()
            RefreshTabs()
            if DF.PinnedFrames then
                DF.PinnedFrames:UpdateLabel(activeHighlightTab)
                -- Refresh preview label text too if a preview is active
                DF.PinnedFrames:UpdatePreviewSet(activeHighlightTab)
            end
        end)
        nameInputContainer.Refresh = function() nameInput:SetText(GetCurrentSet().name or "") end
        -- SetEnabled shim: grey the label + editbox in place when the set is disabled.
        nameInputContainer.SetEnabled = function(_, enabled)
            nameInput:EnableMouse(enabled)
            nameInput:EnableKeyboard(enabled)
            if not enabled then nameInput:ClearFocus() end
            nameInput:SetAlpha(enabled and 1 or 0.4)
            nameLabel:SetAlpha(enabled and 1 or 0.4)
        end
        table.insert(controlsToRefresh, nameInputContainer)
        settingsGroup:AddWidget(nameInputContainer, 48)

        Add(settingsGroup, nil, 1)
        settingsGroup.hideOn = function() return activeSubTab ~= "setup" end  -- Setup tab

        -- Disabled set → grey (disabled-in-place) every OTHER Setup control while the
        -- Enable toggle stays live (keepEnabled above). Each control keeps its OWN
        -- hideOn (soloCheck raid-mode, hideMainCheck boss-mode, disablePvPContainer
        -- editing-layout) — those compose as variant/mode hides on top of the grey.
        settingsGroup.disableChildrenOn = function() return PinnedSetDisabled() end

        -- ===== FRAME TYPE GROUP (Column 2) =====
        local frameTypeGroup = GUI:CreateSettingsGroup(self.child, 280)
        local frameTypeHeader = GUI:CreateHeader(self.child, L["Frame Type"])
        -- Gold "New" badge next to the header (the Friendly Boss NPCs option was
        -- introduced in 4.3.2). Clears when the user navigates away from the
        -- Pinned Frames tab and stays cleared across sessions.
        GUI:AddSectionNewBadge(frameTypeHeader, "general_pinnedframes", "frameType")
        frameTypeGroup:AddWidget(frameTypeHeader, 40)

        local frameTypeOptions = {
            player = L["Player Frames"],
            friendlyBoss = L["Friendly Boss NPCs"],
        }

        local function OnFrameTypeChanged()
            if not DF.PinnedFrames then return end
            -- No combat early-return: the dropdown already wrote set.frameType,
            -- so bailing here left the page AND runtime desynced (Members tab
            -- shown for a now-boss set, wrong Test Count max) until some later
            -- rebuild. Reinitialize self-defers in combat (pendingReinitialize
            -- → PLAYER_REGEN_ENABLED), and the page rebuild isn't secure work.
            DF.PinnedFrames:Reinitialize()
            if GUI.RefreshCurrentPage then GUI.RefreshCurrentPage() end
        end

        frameTypeGroup:AddWidget(
            CreateRefreshableDropdown(self.child, L["Frame Type"], frameTypeOptions, "frameType", OnFrameTypeChanged),
            55
        )

        -- Test Count slider: how many test frames show when Test Mode is
        -- active. Boss mode: 1–8 (hard WoW limit). Party player sets: 1–5
        -- (a party can't exceed 5). Raid player sets: 1–10 (covers typical
        -- pinned set sizes; range kept modest for layout verification).
        local function OnTestCountChanged()
            if not DF.PinnedFrames then return end
            if DF.PinnedFrames.IsTestModeActive and DF.PinnedFrames:IsTestModeActive() then
                DF.PinnedFrames:ExitTestMode()
                DF.PinnedFrames:EnterTestMode()
            end
        end
        local testMax = IsCurrentBossMode() and 8 or (GUI.SelectedMode == "raid" and 10 or 5)
        frameTypeGroup:AddWidget(
            CreateRefreshableSlider(self.child, L["Test Count"], 1, testMax, 1, "testCount", OnTestCountChanged),
            55
        )

        Add(frameTypeGroup, nil, 2)
        frameTypeGroup.hideOn = function() return activeSubTab ~= "setup" end  -- Setup tab
        frameTypeGroup.disableChildrenOn = function() return PinnedSetDisabled() end  -- greyed while the set is disabled
        AddSpace(10, "both")

        -- ===== FRAME STYLE GROUP (Column 1) — inherited from your frames, overridable =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Style"]), 40)

        -- Up-front explainer for the Match inheritance + per-setting override model.
        local matchInfoBanner = GUI:CreateInfoBanner(self.child, {
            tone = "info",
            text = L["Pinned frames are based on your Party or Raid frames — choose which below. Change any setting to override it for these frames; use the reset button beside an overridden setting to revert it to the inherited value."],
        })
        layoutGroup:AddWidget(matchInfoBanner, matchInfoBanner.layoutHeight or 44)

        -- Match (Stage 2a): which mode's main frames this pinned set inherits its
        -- baseline look from. Defaults to the page's OWN mode (a party set mirrors
        -- party frames, a raid set mirrors raid frames); pick the opposite mode to
        -- cross-match it (e.g. raid pinned frames sized/styled like party frames).
        -- Per-set custom overrides (size, etc.) still win over the baseline. It
        -- leads the group because it is the baseline every other option/override
        -- builds on. Seed unset/legacy values to the own mode so it always shows one.
        do
            local pf = DF:GetDB(GUI.SelectedMode)
            pf = pf and pf.pinnedFrames
            if pf and pf.sets then
                for _, s in pairs(pf.sets) do
                    if s.matchMode ~= "party" and s.matchMode ~= "raid" then
                        s.matchMode = GUI.SelectedMode
                    end
                end
            end
        end
        -- Forward refs so the Match dropdown can refresh every Match-override control's
        -- displayed baseline when the matched mode changes (an un-overridden control
        -- then shows the new mode's value; an overridden one keeps its star).
        local pinnedWidthSlider, pinnedHeightSlider, pinnedScaleSlider
        local pinnedHSpacingSlider, pinnedVSpacingSlider
        local function RefreshMatchOverrides()
            if pinnedWidthSlider then pinnedWidthSlider.Refresh() end
            if pinnedHeightSlider then pinnedHeightSlider.Refresh() end
            if pinnedScaleSlider then pinnedScaleSlider.Refresh() end
            if pinnedHSpacingSlider then pinnedHSpacingSlider.Refresh() end
            if pinnedVSpacingSlider then pinnedVSpacingSlider.Refresh() end
        end

        local matchOptions = { party = L["Party"], raid = L["Raid"] }
        layoutGroup:AddWidget(CreateRefreshableDropdown(self.child, L["Based on"], matchOptions, "matchMode", function()
            UpdateHighlightLayout()
            RefreshMatchOverrides()
        end), 55)

        -- Width / Height inherit the Match mode's frame size; changing either
        -- stores a per-set override (gold star + reset-to-Match), exactly like a
        -- layout override but with the Match value as the baseline.
        pinnedWidthSlider = CreateMatchOverrideSlider(self.child, L["Width"], 20, 300, 1, "customWidth", "frameWidth", UpdateHighlightLayout)
        layoutGroup:AddWidget(pinnedWidthSlider, 55)
        pinnedHeightSlider = CreateMatchOverrideSlider(self.child, L["Height"], 10, 200, 1, "customHeight", "frameHeight", UpdateHighlightLayout)
        layoutGroup:AddWidget(pinnedHeightSlider, 55)

        -- Scale inherits the Match mode's frameScale; overridable with star/reset.
        pinnedScaleSlider = CreateMatchOverrideSlider(self.child, L["Scale"], 0.5, 2.0, 0.1, "scale", "frameScale", UpdateHighlightLayout)
        layoutGroup:AddWidget(pinnedScaleSlider, 55)

        -- Per-set Aura / Text Designer preset. "Inherit" (default) follows this mode's
        -- preset; pick a named preset to give this set its own aura/text look. Presets
        -- are created and edited on the Aura/Text Designer pages — here you only choose
        -- which one this pinned set renders with. The Text picker shows whenever the
        -- Text Designer module is loaded.
        layoutGroup:AddWidget(CreatePinnedPresetDropdown(self.child, L["Aura Designer Template"], "aura", "auraDesignerPreset", RefreshPinnedDisplay), 55)
        if DF.TextDesigner then
            layoutGroup:AddWidget(CreatePinnedPresetDropdown(self.child, L["Text Designer Template"], "text", "textDesignerPreset", RefreshPinnedDisplay), 55)
        end

        -- Border Override (Stage 2b): a single toggle. Off → inherit the Based-on
        -- mode's frame border. On → snapshot that border into the set and reveal the
        -- full border controls (independent for this set). The proxy delegates
        -- reads/writes to the current set so CreateBorderControls tracks tab/mode.
        local borderSetProxy = setmetatable({}, {
            __index = function(_, k) local s = GetCurrentSet(); return s and s[k] end,
            __newindex = function(_, k, v) local s = GetCurrentSet(); if s then s[k] = v end end,
        })
        -- Declared first so the border controls' update hooks can refresh the
        -- reset icon's visibility after an edit.
        local borderResetIcon
        local function refreshBorderReset()
            if borderResetIcon then
                borderResetIcon:SetShown(DF.PinnedFrames and DF.PinnedFrames:IsBorderOverrideChanged(GetCurrentSet()) or false)
            end
        end

        local borderCheck = CreateRefreshableCheckbox(self.child, L["Override Border"], "borderOverride", function()
            if GetCurrentSet().borderOverride and DF.PinnedFrames then
                DF.PinnedFrames:SeedSetBorderOverride(GetCurrentSet())
            end
            UpdateHighlightLayout()
            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
        end)
        -- Reset-to-inherited icon on the row's right, matching the refresh icon the
        -- other override controls use. Re-snapshots the border from the Based-on
        -- frames (discards edits). Shown only when a border setting actually differs
        -- from the inherited value.
        do
            local rb = GUI:CreateOverrideResetButton(borderCheck, {
                tooltip = L["Reset Border to Inherited"],
                onClick = function()
                    if DF.PinnedFrames then DF.PinnedFrames:SeedSetBorderOverride(GetCurrentSet(), true) end
                    UpdateHighlightLayout()
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
            })
            rb:SetPoint("TOPRIGHT", borderCheck, "TOPRIGHT", 0, -2)
            borderResetIcon = rb
            local origRefresh = borderCheck.Refresh
            borderCheck.Refresh = function(...) if origRefresh then origRefresh(...) end refreshBorderReset() end
            refreshBorderReset()
        end
        layoutGroup:AddWidget(borderCheck, 28)
        GUI:CreateBorderControls(layoutGroup, borderSetProxy, "frame", {
            parent  = self.child,
            include = {
                inset = true, offset = true, blendMode = true,
                gradient = true, shadow = true,
                classColor = true, roleColor = true,
                alpha = true,
            },
            fullUpdate  = function() UpdateHighlightLayout(); refreshBorderReset() end,
            lightUpdate = function() UpdateHighlightLayout(); refreshBorderReset() end,
            lightColors = function() UpdateHighlightLayout(); refreshBorderReset() end,
            refreshStates = function() if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end end,
            hideWhen   = function() return not (GetCurrentSet() and GetCurrentSet().borderOverride) end,
            sizeMin = 1, sizeMax = 16, sizeStep = 1,
        })

        Add(layoutGroup, nil, 1)
        layoutGroup.hideOn = function() return activeSubTab ~= "appearance" end  -- Appearance tab

        -- ===== LAYOUT GROUP (Column 2) — pinned arrangement. Direction / growth /
        -- units-per-row are pinned-only (no main-frame equivalent). Spacing IS a
        -- Match override: it inherits the Based-on mode's frameSpacing (grouped) /
        -- raidFlat*Spacing (flat) so a pinned set stays aligned with the frames it
        -- mirrors, overridable per set. =====
        local arrangeGroup = GUI:CreateSettingsGroup(self.child, 280)
        arrangeGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout"]), 40)

        -- Direction: how the pinned frames flow (pinned-only; NOT inherited — the
        -- main frames' growDirection means group Rows/Columns, a different concept).
        local directionOptions = { HORIZONTAL= L["Horizontal"], VERTICAL= L["Vertical"] }
        arrangeGroup:AddWidget(CreateRefreshableDropdown(self.child, L["Direction"], directionOptions, "growDirection", UpdateHighlightLayout), 55)

        -- CENTER intentionally omitted: it isn't truly implemented for pinned
        -- frames (frames grow START-style; only the anchor/label shift). START/END
        -- only for now; a real centred layout can be added later.
        local frameAnchorOptions = { START= L["Start (Left/Top)"], END= L["End (Right/Bottom)"] }
        arrangeGroup:AddWidget(CreateRefreshableDropdown(self.child, L["Frames Grow From"], frameAnchorOptions, "frameAnchor", UpdateHighlightLayout), 55)

        local columnAnchorOptions = { START= L["Start (Left/Top)"], END= L["End (Right/Bottom)"] }
        arrangeGroup:AddWidget(CreateRefreshableDropdown(self.child, L["Columns Grow From"], columnAnchorOptions, "columnAnchor", UpdateHighlightLayout), 55)

        arrangeGroup:AddWidget(CreateRefreshableSlider(self.child, L["Units Per Row"], 1, 10, 1, "unitsPerRow", UpdateHighlightLayout), 55)
        -- Spacing inherits the Based-on mode's layout spacing (grouped -> frameSpacing,
        -- flat raid -> raidFlat*Spacing); a per-set value overrides it (gold star + reset).
        local function SpacingBaseline(flatKey)
            return function(mdb)
                if mdb and mdb.raidUseGroups == false then return mdb[flatKey] or 2 end
                return (mdb and mdb.frameSpacing) or 2
            end
        end
        pinnedHSpacingSlider = CreateMatchOverrideSlider(self.child, L["Horizontal Spacing"], -5, 50, 1, "horizontalSpacing", SpacingBaseline("raidFlatHorizontalSpacing"), UpdateHighlightLayout)
        arrangeGroup:AddWidget(pinnedHSpacingSlider, 55)
        pinnedVSpacingSlider = CreateMatchOverrideSlider(self.child, L["Vertical Spacing"], -5, 50, 1, "verticalSpacing", SpacingBaseline("raidFlatVerticalSpacing"), UpdateHighlightLayout)
        arrangeGroup:AddWidget(pinnedVSpacingSlider, 55)
        Add(arrangeGroup, nil, 2)
        arrangeGroup.hideOn = function() return activeSubTab ~= "appearance" end  -- Appearance tab

        if not IsCurrentBossMode() then
        -- ===== MEMBERS SUB-TAB: Unit Selection (roster) first, then Auto-Populate.
        -- Both are "who's in this group", so they lead the Members view; Settings /
        -- Frame Type / Frame Style / Layout live on the Appearance sub-tab. =====
        local membersHideOn = function() return activeSubTab ~= "members" end

        -- Unit Selection header with override indicator
        unitSelHeader = CreateFrame("Frame", nil, self.child)
        unitSelHeader:SetSize(500, 40)
        unitSelHeader.hideOn = membersHideOn
        local unitSelTitle = unitSelHeader:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        unitSelTitle:SetPoint("LEFT", 0, 0)
        unitSelTitle:SetText(L["Unit Selection"])
        -- Match the GUI:CreateHeader norm: theme-colored + auto theme listener
        -- (every sibling section title uses CreateHeader; replicate it here since
        --  this header is composite with a count badge + override indicator).
        local _utc = GUI.GetThemeColor()
        unitSelTitle:SetTextColor(_utc.r, _utc.g, _utc.b)
        unitSelTitle.UpdateTheme = function()
            local nc = GUI.GetThemeColor()
            unitSelTitle:SetTextColor(nc.r, nc.g, nc.b)
        end
        if not self.child.ThemeListeners then self.child.ThemeListeners = {} end
        table.insert(self.child.ThemeListeners, unitSelTitle)

        -- "N pinned" count beside the title, themed. Updated on any roster change.
        local unitSelCount = unitSelHeader:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        unitSelCount:SetPoint("LEFT", unitSelTitle, "RIGHT", 8, 0)
        local function UpdateUnitSelCount()
            local n = #((GetCurrentSet() and GetCurrentSet().players) or {})
            unitSelCount:SetText(n .. " " .. L["pinned"])
            local tc = GUI.GetThemeColor()
            unitSelCount:SetTextColor(tc.r, tc.g, tc.b)
        end
        UpdateUnitSelCount()

        -- Override indicator for players list (header-level)
        AddPinnedOverrideIndicators(unitSelHeader, unitSelTitle, "players", function()
            local AutoProfilesUI = DF.AutoProfilesUI
            if AutoProfilesUI then
                AutoProfilesUI:ResetProfileSetting(GetPinnedKey("players"))
                if rosterWidget and rosterWidget.Refresh then rosterWidget:Refresh() end
                if DF.PinnedFrames then DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab) end
                if unitSelHeader.UpdateOverrideIndicators then unitSelHeader:UpdateOverrideIndicators() end
            end
        end)
        unitSelHeader.Refresh = function(self)
            if self.UpdateOverrideIndicators then self:UpdateOverrideIndicators() end
            UpdateUnitSelCount()
        end

        Add(unitSelHeader, 40, "both")

        rosterWidget = GUI:CreateHighlightRosterWidget(
            self.child,
            function() return GetCurrentSet().players end,
            function(players)
                local set = GetCurrentSet()
                set.players = players
                -- Sync manualPlayers: every player currently in the list via GUI is manual.
                -- Rebuild the lookup to match exactly what's in the list now.
                if not set.manualPlayers then set.manualPlayers = {} end
                local newManual = {}
                for _, name in ipairs(players) do
                    -- Preserve existing manual entries, add any new ones
                    newManual[name] = true
                end
                set.manualPlayers = newManual
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                    -- Deep copy the players array for the override
                    local copy = {}
                    for i, v in ipairs(players) do copy[i] = v end
                    DF.AutoProfilesUI:SetProfileSetting(GetPinnedKey("players"), copy)
                    if unitSelHeader.UpdateOverrideIndicators then unitSelHeader:UpdateOverrideIndicators() end
                end
            end,
            function()
                if DF.PinnedFrames then DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab) end
            end
        )

        local originalRefresh = rosterWidget.Refresh
        rosterWidget.Refresh = function(s)
            if originalRefresh then originalRefresh(s) end
            if unitSelHeader.UpdateOverrideIndicators then unitSelHeader:UpdateOverrideIndicators() end
            UpdateUnitSelCount()
            RefreshTabs()  -- keep the tab member count in sync with the roster
        end
        table.insert(controlsToRefresh, rosterWidget)
        table.insert(controlsToRefresh, unitSelHeader)
        -- The roster widget's content runs to ~364px (panes 240 + role buttons +
        -- the "Add Offline Player" input), taller than its 340 frame. Reserve the
        -- real height (plus a gap) so the following Auto-Populate group doesn't ride
        -- up into the manual-entry row.
        Add(rosterWidget, 378, "both")
        rosterWidget.hideOn = membersHideOn

        -- ===== AUTO-POPULATE GROUP (full width, under the roster) =====
        local autoPopGroup = GUI:CreateSettingsGroup(self.child, 560)
        autoPopGroup:AddWidget(GUI:CreateHeader(self.child, L["Auto-Populate"]), 40)
        autoPopGroup:AddWidget(GUI:CreateLabel(self.child, L["Automatically add players by role when they join your group."], 510), 20)

        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Auto-add Tanks"], "autoAddTanks", function()
            if GetCurrentSet().autoAddTanks and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
                SyncPlayersOverride()
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Auto-add Healers"], "autoAddHealers", function()
            if GetCurrentSet().autoAddHealers and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
                SyncPlayersOverride()
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Auto-add DPS"], "autoAddDPS", function()
            if GetCurrentSet().autoAddDPS and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
                SyncPlayersOverride()
            end
        end), 28)
        -- Exclude Self: keep the player out of this set's auto-add (e.g. Aug Evoker
        -- who buffs others). Re-runs auto-populate so self is added/removed live.
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Exclude Self"], "excludeSelf", function()
            if DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
                SyncPlayersOverride()
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Keep when offline/left"], "keepOfflinePlayers", function() end, L["Keep when offline/left Tooltip"]), 28)

        Add(autoPopGroup, nil, "both")
        autoPopGroup.hideOn = membersHideOn
        end -- not IsCurrentBossMode

        RefreshControls()

        -- Show preview containers if editing a non-active mode
        -- (e.g. raid settings while actually in a party): lets the user
        -- position/scale the pinned frames for that mode without being in it.
        if DF.PinnedFrames then
            DF.PinnedFrames:ShowPreview(GUI.SelectedMode)
        end
    end)

    DF._SetupGUIPagesPart3(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
end