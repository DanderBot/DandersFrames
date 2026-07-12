local addonName, DF = ...
local format = string.format

-- ============================================================
-- GUI PAGE SETUP - Collapsible Category System
-- ============================================================

function DF:SetupGUIPages(GUI, CreateCategory, CreateSubTab, BuildPage)
    local L = DF.L
    
    -- Helper function to create a themed "Copy to Raid/Party" button for a section.
    -- Pass omitReset=true for pages that manage their own reset flow (Aura Designer,
    -- Click Casting) so they only get the Sync/Copy pair, not the destructive trio.
    local function CreateCopyButton(parent, prefixes, sectionName, pageId, omitReset)
        -- Register section in the sync registry
        if pageId then
            DF.SectionRegistry[pageId] = prefixes
        end

        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(115, 26)
        -- Copy is a normal button; the shared styler owns the backdrop/hover AND
        -- the icon+label layout via the icon/text opts. (Label set per-mode below.)
        GUI:StyleButton(btn, {
            icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\content_copy", size = 18, color = { r = 0.9, g = 0.9, b = 0.9 } },
            text = L["Copy to Raid"],
        })
        
        -- Sync toggle button
        local linkBtn
        if pageId then
            linkBtn = CreateFrame("Button", nil, btn, "BackdropTemplate")
            linkBtn:SetSize(120, 26)
            linkBtn:SetPoint("RIGHT", btn, "LEFT", -4, 0)
            -- Sync is a toggle (SetActive when linked) on the shared styler.
            -- fadeActiveText: the synced label recedes slightly while linked.
            GUI:StyleButton(linkBtn, {
                fadeActiveText = true,
                -- icon swaps sync / sync_disabled with the linked state (set in UpdateAppearance)
                icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\sync_disabled", size = 18, color = { r = 0.9, g = 0.9, b = 0.9 } },
                text = L["Sync with Raid"],
            })
        end

        -- Update appearance based on current mode
        local function UpdateAppearance()
            local mode = GUI.SelectedMode or "party"

            if mode == "party" then
                btn.Text:SetText(L["Copy to Raid"])
            else
                btn.Text:SetText(L["Copy to Party"])
            end
            -- Content-size so short labels aren't swimming in padding (icon+gap ~18 + ~9px each side).
            btn:SetWidth(math.ceil(btn.Text:GetStringWidth()) + 36)

            -- Copy is a normal button; StyleButton owns its backdrop/hover.
            btn.Text:SetTextColor(0.9, 0.9, 0.9)
            btn.Icon:SetVertexColor(0.9, 0.9, 0.9)

            -- Update sync button appearance
            if linkBtn then
                local dest = mode == "party" and L["Raid"] or L["Party"]
                local isLinked = DF.db and DF.db.linkedSections and DF.db.linkedSections[pageId]
                -- State shown by the toggle border/fill (SetActive) + the label
                -- word; text stays white in both states, like the other toggles.
                linkBtn:SetActive(isLinked)
                linkBtn.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. (isLinked and "sync" or "sync_disabled"))
                linkBtn.Text:SetText(isLinked and format(L["Synced with %s"], dest) or format(L["Sync with %s"], dest))
                linkBtn.Text:SetTextColor(0.9, 0.9, 0.9)
                linkBtn.Icon:SetVertexColor(0.9, 0.9, 0.9)
                linkBtn:SetWidth(math.ceil(linkBtn.Text:GetStringWidth()) + 36)
            end
        end
        
        -- Store for refresh
        btn.UpdateModeText = UpdateAppearance
        btn.rightAlign = true  -- Flag for layout system
        
        -- Copy tooltip (HookScript so it composes with the StyleButton hover).
        btn:HookScript("OnEnter", function(self)
            local mode = GUI.SelectedMode or "party"
            local src = mode == "party" and L["Party"] or L["Raid"]
            local dest = mode == "party" and L["Raid"] or L["Party"]
            GUI:ShowTooltip(self, {
                title = format(L["Copy %s Settings"], sectionName),
                lines = {
                    format(L["Copies these settings from %s to %s."], src, dest),
                },
            })
        end)
        btn:HookScript("OnLeave", function()
            GameTooltip:Hide()
            UpdateAppearance()  -- keep the Copy/Sync labels fresh after state changes
        end)
        
        btn:SetScript("OnClick", function()
            local mode = GUI.SelectedMode or "party"
            local dest = mode == "party" and L["Raid"] or L["Party"]
            DF:ShowPopupAlert({
                title = format(L["Copy %s Settings"], sectionName),
                message = format(L["Copy %s settings to %s?"], sectionName, dest),
                buttons = {
                    {
                        label = L["Copy"],
                        onClick = function()
                            DF:CopySectionSettings(prefixes, mode)
                            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end)

        -- Sync button event handlers
        if linkBtn then
            linkBtn:HookScript("OnEnter", function(self)
                local isLinked = DF.db and DF.db.linkedSections and DF.db.linkedSections[pageId]
                if isLinked then
                    GUI:ShowTooltip(self, {
                        title = format(L["Synced: %s"], sectionName),
                        lines = {
                            format(L["Party & Raid %s settings are synced.\nClick to stop syncing."], sectionName),
                        },
                    })
                else
                    GUI:ShowTooltip(self, {
                        title = format(L["Sync: %s"], sectionName),
                        lines = {
                            format(L["Click to sync Party & Raid %s settings.\nChanges in one mode will automatically apply to the other."], sectionName),
                        },
                    })
                end
            end)
            linkBtn:HookScript("OnLeave", function()
                GameTooltip:Hide()
                UpdateAppearance()  -- re-read the synced state so the label updates without /reload
            end)

            linkBtn:SetScript("OnClick", function()
                if not DF.db then return end
                if not DF.db.linkedSections then DF.db.linkedSections = {} end

                if DF.db.linkedSections[pageId] then
                    DF.db.linkedSections[pageId] = nil
                    UpdateAppearance()
                else
                    local mode = GUI.SelectedMode or "party"
                    local dest = mode == "party" and L["Raid"] or L["Party"]
                    DF:ShowPopupAlert({
                        title = format(L["Sync: %s"], sectionName),
                        message = format(L["Sync %s settings?\n\nThis will copy current %s settings to %s and keep them in sync."], sectionName, sectionName, dest),
                        buttons = {
                            {
                                label = L["Sync"],
                                onClick = function()
                                    DF.db.linkedSections[pageId] = true
                                    DF:CopySectionSettings(prefixes, mode)
                                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                                end,
                            },
                            { label = L["Cancel"] },
                        },
                    })
                end
            end)
        end
        
        -- Reset to defaults button (red, destructive — leftmost in the trio).
        -- Static red palette (no theme listener) so it visually flags as
        -- destructive vs. the theme-coloured Copy/Sync buttons.
        if not omitReset then
            local resetBtn = CreateFrame("Button", nil, btn, "BackdropTemplate")
            resetBtn:SetSize(115, 26)
            if linkBtn then
                resetBtn:SetPoint("RIGHT", linkBtn, "LEFT", -4, 0)
            else
                resetBtn:SetPoint("RIGHT", btn, "LEFT", -4, 0)
            end

            -- Destructive Reset: the shared danger tone owns the red label/icon +
            -- red hover; we keep the content-fit width + the tooltip hook.
            GUI:StyleButton(resetBtn, {
                tone = "danger",
                icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh", size = 18 },
                text = L["Reset Page"],
            })
            resetBtn:SetWidth(math.ceil(resetBtn.Text:GetStringWidth()) + 36)

            resetBtn:HookScript("OnEnter", function(self)
                local mode = GUI.SelectedMode or "party"
                local m = (mode == "party") and L["Party"] or L["Raid"]
                GUI:ShowTooltip(self, {
                    title = format(L["Reset: %s"], sectionName),
                    lines = {
                        format(L["Reset %s settings on %s mode to defaults. Other settings are not affected."], sectionName, m),
                    },
                })
            end)
            resetBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

            resetBtn:SetScript("OnClick", function()
                local mode = GUI.SelectedMode or "party"
                local m = (mode == "party") and L["Party"] or L["Raid"]
                DF:ShowPopupAlert({
                    title = format(L["Reset: %s"], sectionName),
                    message = format(L["Reset %s settings to defaults?\n\nThis only affects %s settings on the current %s mode. This cannot be undone."], sectionName, sectionName, m),
                    buttons = {
                        {
                            label = L["Reset"],
                            onClick = function()
                                DF:ResetSectionSettings(prefixes, mode)
                                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                            end,
                        },
                        { label = L["Cancel"] },
                    },
                })
            end)
        end

        -- Initial update
        UpdateAppearance()

        -- Register for theme updates
        if not parent.ThemeListeners then parent.ThemeListeners = {} end
        table.insert(parent.ThemeListeners, {UpdateTheme = UpdateAppearance})

        return btn
    end

    -- Expose for use by sub-pages (e.g. Aura Designer)
    GUI.CreateCopyButton = CreateCopyButton

    -- Standalone Reset button for pages whose settings aren't mode-specific
    -- and so don't get the full Sync/Copy trio. Uses the same red palette and
    -- confirmation popup style as the trio's Reset button.
    --
    --   parent:        widget parent (typically self.child inside BuildPage)
    --   sectionName:   localised page name, used in the popup and tooltip
    --   onReset:       callback that performs the actual reset; the helper
    --                  handles the confirmation popup before invoking this
    --   warningText:   optional extra line below the standard message (string)
    local function CreateResetOnlyButton(parent, sectionName, onReset, warningText)
        local resetBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        resetBtn:SetSize(115, 26)
        resetBtn.rightAlign = true

        -- Destructive Reset: shared danger tone (red label/icon + red hover) +
        -- content-fit width + tooltip hook.
        GUI:StyleButton(resetBtn, {
            tone = "danger",
            icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh", size = 18 },
            text = L["Reset Page"],
        })
        resetBtn:SetWidth(math.ceil(resetBtn.Text:GetStringWidth()) + 36)

        resetBtn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, {
                title = format(L["Reset: %s"], sectionName),
                lines = {
                    format(L["Reset %s settings to defaults. This cannot be undone."], sectionName),
                },
            })
        end)
        resetBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

        resetBtn:SetScript("OnClick", function()
            local message = format(L["Reset %s settings to defaults?\n\nThis cannot be undone."], sectionName)
            if warningText and warningText ~= "" then
                message = format(L["Reset %s settings to defaults?\n\n%s\n\nThis cannot be undone."], sectionName, warningText)
            end
            DF:ShowPopupAlert({
                title = format(L["Reset: %s"], sectionName),
                message = message,
                buttons = {
                    {
                        label = L["Reset"],
                        onClick = function()
                            if onReset then onReset() end
                            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end)

        return resetBtn
    end

    GUI.CreateResetOnlyButton = CreateResetOnlyButton

    -- Define category order (updated structure)
    GUI.CategoryOrder = {"general", "clickcast", "display", "bars", "text", "auras", "indicators", "profiles", "debug"}
    
    -- ========================================
    -- CATEGORY: General
    -- ========================================
    CreateCategory("general", L["General"])
    
    -- ========================================
    -- CATEGORY: Display (new top-level category)
    -- ========================================
    CreateCategory("display", L["Display"])
    
    -- Display > Visibility
    local pageVisibility = CreateSubTab("display", "display_visibility", L["Visibility"])
    BuildPage(pageVisibility, function(self, db, Add, AddSpace, AddSyncPoint)
        Add(CreateCopyButton(self.child, {"soloMode", "hidePlayerFrame", "restedIndicator"}, L["Visibility"], "display_visibility"), 25, 2)

        -- ===== FRAME DISPLAY GROUP (Column 1) =====
        local frameDisplayGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameDisplayGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Display"]), 40)
        
        local soloMode = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Solo Mode"], db, "soloMode", function()
            DF:UpdateAllFrames()
            DF:UpdateDefaultPlayerFrame()
        end), 30)
        soloMode.hideOn = function() return GUI.SelectedMode == "raid" end
        
        local restedIndicator = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Rested Indicator"], db, "restedIndicator", function()
            DF:UpdateRestedIndicator()
        end), 30)
        restedIndicator.hideOn = function() return GUI.SelectedMode == "raid" end
        restedIndicator.disableOn = function(d) return not d.soloMode end
        restedIndicator.tooltip = L["Show rested indicators when in a rested area (inn, city)."]
        
        local restedIcon = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, L["    Show ZZZ Icon"], db, "restedIndicatorIcon", function()
            DF:UpdateRestedIndicator()
        end), 30)
        restedIcon.hideOn = function() return GUI.SelectedMode == "raid" end
        restedIcon.disableOn = function(d) return not d.soloMode or not d.restedIndicator end
        restedIcon.tooltip = L["Show the animated ZZZ icon on the player frame."]
        
        local restedGlow = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, L["    Show Frame Glow"], db, "restedIndicatorGlow", function()
            DF:UpdateRestedIndicator()
        end), 30)
        restedGlow.hideOn = function() return GUI.SelectedMode == "raid" end
        restedGlow.disableOn = function(d) return not d.soloMode or not d.restedIndicator end
        restedGlow.tooltip = L["Show a pulsing yellow glow around the frame."]
        
        local soloNote = frameDisplayGroup:AddWidget(GUI:CreateLabel(self.child, L["Solo Mode: Show your player frame when not in a group."], 250), 30)
        soloNote.hideOn = function() return GUI.SelectedMode == "raid" end
        
        local hidePlayer = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Self from Party Frames"], db, "hidePlayerFrame", function()
            -- Update the secure header's showPlayer attribute
            if not InCombatLockdown() and DF.partyHeader then
                DF.partyHeader:SetAttribute("showPlayer", not db.hidePlayerFrame)
            end
            -- Reapply header settings to reposition frames
            if DF.ApplyHeaderSettings then
                DF:ApplyHeaderSettings()
            end
            DF:UpdateAllFrames()
        end), 30)
        hidePlayer.hideOn = function() return GUI.SelectedMode == "raid" end
        hidePlayer.tooltip = L["Removes your player frame from the DandersFrames party display."]

        Add(frameDisplayGroup, nil, 1)
    end)
    -- The Visibility tab is entirely party/solo-oriented, so hide it in raid mode.
    if GUI.Tabs and GUI.Tabs["display_visibility"] then
        GUI.Tabs["display_visibility"].partyOnly = true
    end
    
    -- Display > Tooltips (moved from General)
    local pageTooltips = CreateSubTab("display", "display_tooltips", L["Tooltips"])
    BuildPage(pageTooltips, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right (positioned automatically via rightAlign)
        Add(CreateCopyButton(self.child, {"tooltip"}, L["Tooltips"], "display_tooltips"), 25, 2)
        
        -- Anchor position values (shared)
        local anchorPositionValues = {
            TOPLEFT = L["Top Left"],
            TOP = L["Top"],
            TOPRIGHT = L["Top Right"],
            LEFT = L["Left"],
            CENTER = L["Center"],
            RIGHT = L["Right"],
            BOTTOMLEFT = L["Bottom Left"],
            BOTTOM = L["Bottom"],
            BOTTOMRIGHT = L["Bottom Right"],
        }
        
        -- ===== ROW 1: Frame Tooltips + Buff Tooltips =====
        
        -- Frame Tooltips (Column 1)
        local frameTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Tooltips"]), 40)
        local frameTooltipEnable = frameTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Frame Tooltips"], db, "tooltipFrameEnabled", nil), 30)
        frameTooltipEnable.keepEnabled = true
        frameTooltipGroup.disableChildrenOn = function(d) return not d.tooltipFrameEnabled end
        frameTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Disable in Combat"], db, "tooltipFrameDisableInCombat", function() end), 30)
        
        local frameAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Unit Frame"],
        }
        frameTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], frameAnchorValues, db, "tooltipFrameAnchor", function() GUI:RefreshCurrentPage() end), 55)
        
        local frameAnchorPos = frameTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipFrameAnchorPos", function() end), 55)
        frameAnchorPos.disableOn = function(d) return d.tooltipFrameAnchor == "DEFAULT" end
        
        local frameOffsetX = frameTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "tooltipFrameX", function() end), 55)
        frameOffsetX.disableOn = function(d) return d.tooltipFrameAnchor ~= "FRAME" end
        
        local frameOffsetY = frameTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "tooltipFrameY", function() end), 55)
        frameOffsetY.disableOn = function(d) return d.tooltipFrameAnchor ~= "FRAME" end
        
        Add(frameTooltipGroup, nil, 1)
        
        -- Buff Tooltips (Column 2)
        local buffTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        buffTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Buff Tooltips"]), 40)
        -- 12.1 factory rows read these at build (mouse-motion opt-in, in the row sig) —
        -- a toggle must invalidate so the rebuild picks it up. Legacy reads at hover (free).
        local RefreshAuraTooltips = function()
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            DF:UpdateAllFrames()
        end
        local buffTooltipEnable = buffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Buff Tooltips"], db, "tooltipBuffEnabled", RefreshAuraTooltips), 30)
        buffTooltipEnable.keepEnabled = true
        buffTooltipGroup.disableChildrenOn = function(d) return not d.tooltipBuffEnabled end
        -- Permanent 12.1 limitation: the aura button's mouse state is secret and
        -- write-locked in combat, so the native hover can't be dropped per-combat
        -- (live-verified — the insecure SetMouseMotionEnabled flip no-ops in combat).
        local buffTtCombat = buffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Disable in Combat"], db, "tooltipBuffDisableInCombat", function() end), 30)
        GUI:BlockControl12_1(buffTtCombat, "limitation", { id = "tooltips:buffcombat", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsBuffRow(d) end })
        -- Position controls below are a PERMANENT 12.1 limitation: the game's aura
        -- tooltip is a forbidden object with a hardcoded anchor (source-verified;
        -- even Blizzard's own frames get no say). Explain rather than just grey.
        local buffTipNote = buffTooltipGroup:AddWidget(GUI:CreateNote(self.child,
            L["On 12.1 the game draws aura tooltips at a fixed position beside the icon."],
            { width = 260 }), 40)
        buffTipNote.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end

        local buffAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Buff Icon"],
        }
        local buffTtAnchorTo = buffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], buffAnchorValues, db, "tooltipBuffAnchor", function() GUI:RefreshCurrentPage() end), 55)
        GUI:BlockControl12_1(buffTtAnchorTo, "limitation", { id = "tooltips:buffanchorto", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsBuffRow(d) end })
        
        local buffAnchorPos = buffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipBuffAnchorPos", function() end), 55)
        buffAnchorPos.disableOn = function(d) return d.tooltipBuffAnchor == "DEFAULT" end
        GUI:BlockControl12_1(buffAnchorPos, "limitation", { id = "tooltips:buffanchorpos", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsBuffRow(d) end })
        
        local buffOffsetX = buffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "tooltipBuffX", function() end), 55)
        buffOffsetX.disableOn = function(d) return d.tooltipBuffAnchor ~= "FRAME" end
        GUI:BlockControl12_1(buffOffsetX, "limitation", { id = "tooltips:buffoffsetx", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsBuffRow(d) end })
        
        local buffOffsetY = buffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "tooltipBuffY", function() end), 55)
        buffOffsetY.disableOn = function(d) return d.tooltipBuffAnchor ~= "FRAME" end
        GUI:BlockControl12_1(buffOffsetY, "limitation", { id = "tooltips:buffoffsety", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsBuffRow(d) end })
        
        Add(buffTooltipGroup, nil, 2)
        
        -- Sync point: align row 2 to start at the same level
        AddSyncPoint()
        
        -- ===== ROW 2: Debuff Tooltips + Defensive Icon Tooltips =====
        
        -- Debuff Tooltips (Column 1)
        local debuffTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        debuffTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Debuff Tooltips"]), 40)
        local debuffTooltipEnable = debuffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Debuff Tooltips"], db, "tooltipDebuffEnabled", RefreshAuraTooltips), 30)
        debuffTooltipEnable.keepEnabled = true
        debuffTooltipGroup.disableChildrenOn = function(d) return not d.tooltipDebuffEnabled end
        -- Permanent 12.1 limitation (see the buff group): combat hover-drop no-ops.
        local debuffTtCombat = debuffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Disable in Combat"], db, "tooltipDebuffDisableInCombat", function() end), 30)
        GUI:BlockControl12_1(debuffTtCombat, "limitation", { id = "tooltips:debuffcombat", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDebuffRow(d) end })
        local debuffTipNote = debuffTooltipGroup:AddWidget(GUI:CreateNote(self.child,
            L["On 12.1 the game draws aura tooltips at a fixed position beside the icon."],
            { width = 260 }), 40)
        debuffTipNote.hideOn = function(d) return not DF:FactoryOwnsDebuffRow(d) end

        local debuffAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Debuff Icon"],
        }
        local debuffTtAnchorTo = debuffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], debuffAnchorValues, db, "tooltipDebuffAnchor", function() GUI:RefreshCurrentPage() end), 55)
        GUI:BlockControl12_1(debuffTtAnchorTo, "limitation", { id = "tooltips:debuffanchorto", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDebuffRow(d) end })
        
        local debuffAnchorPos = debuffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipDebuffAnchorPos", function() end), 55)
        debuffAnchorPos.disableOn = function(d) return d.tooltipDebuffAnchor == "DEFAULT" end
        GUI:BlockControl12_1(debuffAnchorPos, "limitation", { id = "tooltips:debuffanchorpos", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDebuffRow(d) end })
        
        local debuffOffsetX = debuffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "tooltipDebuffX", function() end), 55)
        debuffOffsetX.disableOn = function(d) return d.tooltipDebuffAnchor ~= "FRAME" end
        GUI:BlockControl12_1(debuffOffsetX, "limitation", { id = "tooltips:debuffoffsetx", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDebuffRow(d) end })
        
        local debuffOffsetY = debuffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "tooltipDebuffY", function() end), 55)
        debuffOffsetY.disableOn = function(d) return d.tooltipDebuffAnchor ~= "FRAME" end
        GUI:BlockControl12_1(debuffOffsetY, "limitation", { id = "tooltips:debuffoffsety", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDebuffRow(d) end })
        
        Add(debuffTooltipGroup, nil, 1)
        
        -- Defensive Icon Tooltips (Column 2)
        local defTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        defTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Defensive Icon Tooltips"]), 40)
        local defTooltipEnable = defTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Defensive Icon Tooltips"], db, "tooltipDefensiveEnabled", RefreshAuraTooltips), 30)
        defTooltipEnable.keepEnabled = true
        defTooltipGroup.disableChildrenOn = function(d) return not d.tooltipDefensiveEnabled end
        -- Permanent 12.1 limitation (see the buff group): combat hover-drop no-ops.
        local defTtCombat = defTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Disable in Combat"], db, "tooltipDefensiveDisableInCombat", function() end), 30)
        GUI:BlockControl12_1(defTtCombat, "limitation", { id = "tooltips:defensivecombat", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDefensiveRow(d) end })
        local defTipNote = defTooltipGroup:AddWidget(GUI:CreateNote(self.child,
            L["On 12.1 the game draws aura tooltips at a fixed position beside the icon."],
            { width = 260 }), 40)
        defTipNote.hideOn = function(d) return not DF:FactoryOwnsDefensiveRow(d) end

        local defAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Defensive Icon"],
        }
        local defTtAnchorTo = defTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], defAnchorValues, db, "tooltipDefensiveAnchor", function() GUI:RefreshCurrentPage() end), 55)
        GUI:BlockControl12_1(defTtAnchorTo, "limitation", { id = "tooltips:defensiveanchorto", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDefensiveRow(d) end })
        
        local defAnchorPos = defTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipDefensiveAnchorPos", function() end), 55)
        defAnchorPos.disableOn = function(d) return d.tooltipDefensiveAnchor == "DEFAULT" end
        GUI:BlockControl12_1(defAnchorPos, "limitation", { id = "tooltips:defensiveanchorpos", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDefensiveRow(d) end })
        
        local defOffsetX = defTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "tooltipDefensiveX", function() end), 55)
        defOffsetX.disableOn = function(d) return d.tooltipDefensiveAnchor ~= "FRAME" end
        GUI:BlockControl12_1(defOffsetX, "limitation", { id = "tooltips:defensiveoffsetx", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDefensiveRow(d) end })
        
        local defOffsetY = defTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "tooltipDefensiveY", function() end), 55)
        defOffsetY.disableOn = function(d) return d.tooltipDefensiveAnchor ~= "FRAME" end
        GUI:BlockControl12_1(defOffsetY, "limitation", { id = "tooltips:defensiveoffsety", page = L["Tooltips"], when = function(d) return DF:FactoryOwnsDefensiveRow(d) end })
        
        Add(defTooltipGroup, nil, 2)

        -- Resurrection Icon Tooltips (Column 3)
        local resTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        resTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Resurrection Icon Tooltips"]), 40)
        resTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Resurrection Icon Tooltips"], db, "tooltipResurrectionEnabled", nil), 30)
        Add(resTooltipGroup, nil, 2)

        -- Sync point: align row 3
        AddSyncPoint()

        -- ===== ROW 3: Binding Tooltips =====

        -- Binding Tooltips (Column 1)
        local bindTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        bindTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Binding Tooltips"]), 40)
        local bindTooltipEnable = bindTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Binding Tooltips"], db, "tooltipBindingEnabled", nil), 30)
        bindTooltipEnable.keepEnabled = true
        bindTooltipGroup.disableChildrenOn = function(d) return not d.tooltipBindingEnabled end
        bindTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Disable in Combat"], db, "tooltipBindingDisableInCombat", function() end), 30)

        local bindAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Unit Frame"],
        }
        bindTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], bindAnchorValues, db, "tooltipBindingAnchor", function() GUI:RefreshCurrentPage() end), 55)

        local bindAnchorPos = bindTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipBindingAnchorPos", function() end), 55)
        bindAnchorPos.disableOn = function(d) return d.tooltipBindingAnchor == "DEFAULT" end

        local bindOffsetX = bindTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "tooltipBindingX", function() end), 55)
        bindOffsetX.disableOn = function(d) return d.tooltipBindingAnchor ~= "FRAME" end

        local bindOffsetY = bindTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "tooltipBindingY", function() end), 55)
        bindOffsetY.disableOn = function(d) return d.tooltipBindingAnchor ~= "FRAME" end

        Add(bindTooltipGroup, nil, 1)

        -- Sync point before See Also
        AddSyncPoint()
        AddSpace(20, "both")

        -- See Also links
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buffs"]},
            {pageId = "auras_debuffs", label = L["Debuffs"]},
            {pageId = "auras_defensiveicon", label = L["Defensive Icon"]},
        }), 30, "both")
    end)
    
    -- Display > Fading (moved from Indicators > Out of Range + Dead/Offline fading)
    local pageFading = CreateSubTab("display", "display_fading", L["Fading"])
    BuildPage(pageFading, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right
        Add(CreateCopyButton(self.child, {"rangeFade", "oor", "dead", "offline", "healthFade", "hf"}, L["Fading"], "display_fading"), 25, 2)
        
        -- Sync point: ensures both columns start below the copy button
        AddSpace(10, "both")
        
        -- Element-specific alpha sliders grey out (disabled-in-place) when the
        -- "Enable Element-Specific Alpha" toggle is off. The frame-level alpha
        -- slider is the alternate variant (shown only when element-specific is
        -- off) so it keeps a hideOn, not a grey.
        local function HideOOROptions(d)
            return not d.oorEnabled
        end
        
        -- Helper to check if frame-level alpha should be hidden (when element-specific is enabled)
        local function HideFrameLevelAlpha(d)
            return d.oorEnabled
        end
        
        -- ===== OUT OF RANGE GROUP (Column 1) =====
        local oorGroup = GUI:CreateSettingsGroup(self.child, 280)
        oorGroup:AddWidget(GUI:CreateHeader(self.child, L["Out of Range"]), 40)
        
        -- Build dropdown options dynamically
        local function GetRangeSpellDropdownOptions()
            local options = {}
            if DF.GetRangeSpellOptions then
                local spellOptions = DF:GetRangeSpellOptions()
                for _, opt in ipairs(spellOptions) do
                    options[opt.value] = opt.label
                end
            else
                options[0] = L["Auto (Spec Default)"]
            end
            return options
        end
        
        -- Ensure db value is not nil (default to 0 = Auto)
        if db.rangeCheckSpellID == nil then
            db.rangeCheckSpellID = 0
        end
        
        -- Helper to refresh info label
        local function RefreshRangeInfoLabel()
            if self.rangeSpellInfoLabel and self.rangeSpellInfoLabel.SetText and DF.GetCurrentRangeSpellInfo then
                local info = DF:GetCurrentRangeSpellInfo()
                self.rangeSpellInfoLabel:SetText("|cFFAAAAAA" .. L["Active:"] .. " " .. (info.spellName or "None") .. " (" .. (info.range or "?") .. ")|r")
            end
        end
        
        -- Set value callback - called AFTER dropdown has already set db.rangeCheckSpellID
        local function SetRangeSpellValue()
            local value = db.rangeCheckSpellID or 0
            if DF.SetRangeCheckSpell then
                DF:SetRangeCheckSpell(value)
            end
            RefreshRangeInfoLabel()
            if self.rangeSpellInput and self.rangeSpellInput.EditBox then
                self.rangeSpellInput.EditBox:SetText("")
            end
        end
        
        -- Range Check Spell row
        local rangeSpellDropdown = oorGroup:AddWidget(GUI:CreateDropdown(self.child, L["Range Check Spell"], GetRangeSpellDropdownOptions(), db, "rangeCheckSpellID", SetRangeSpellValue), 55)
        rangeSpellDropdown.tooltip = L["Select which spell to use for range checking. Auto will use your spec's default healing/friendly spell."]
        
        -- Custom Spell ID Input
        local customSpellInput = oorGroup:AddWidget(GUI:CreateInput(self.child, L["Custom Spell ID"], 120), 55)
        customSpellInput.tooltip = L["Enter any spell ID for range checking. Press Enter to apply. Leave empty to use dropdown selection."]
        self.rangeSpellInput = customSpellInput
        
        -- Set initial value if it's a custom spell not in dropdown
        if db.rangeCheckSpellID and db.rangeCheckSpellID > 0 then
            local isInDropdown = false
            if DF.GetRangeSpellOptions then
                for _, opt in ipairs(DF:GetRangeSpellOptions()) do
                    if opt.value == db.rangeCheckSpellID then
                        isInDropdown = true
                        break
                    end
                end
            end
            if not isInDropdown then
                customSpellInput.EditBox:SetText(tostring(db.rangeCheckSpellID))
            end
        end
        
        customSpellInput.EditBox:SetNumeric(true)
        customSpellInput.EditBox:SetMaxLetters(8)
        
        local function ApplyCustomSpellID()
            local text = customSpellInput.EditBox:GetText()
            local spellID = tonumber(text)
            
            if not text or text == "" then
                return
            end
            
            if spellID and spellID > 0 then
                local spellName = C_Spell.GetSpellName(spellID)
                if spellName then
                    db.rangeCheckSpellID = spellID
                    if DF.SetRangeCheckSpell then
                        DF:SetRangeCheckSpell(spellID)
                    end
                    RefreshRangeInfoLabel()
                    print("|cFF00FF00[DFRange]|r Custom spell set: " .. spellName .. " (ID: " .. spellID .. ")")
                else
                    print("|cFFFF0000[DFRange]|r Invalid spell ID: " .. spellID)
                    customSpellInput.EditBox:SetText("")
                end
            end
        end
        
        customSpellInput.EditBox:SetScript("OnEnterPressed", function(self)
            ApplyCustomSpellID()
            self:ClearFocus()
        end)
        customSpellInput.EditBox:SetScript("OnEditFocusLost", function(self)
            ApplyCustomSpellID()
        end)
        
        -- Info label showing current active spell
        local rangeInfoText = L["Loading..."]
        if DF.GetCurrentRangeSpellInfo then
            local rangeInfo = DF:GetCurrentRangeSpellInfo()
            rangeInfoText = (rangeInfo.spellName or "None") .. " (" .. (rangeInfo.range or "?") .. ")"
        end
        local infoLabel = oorGroup:AddWidget(GUI:CreateLabel(self.child, "|cFFAAAAAA" .. L["Active:"] .. " " .. rangeInfoText .. "|r", 250), 25)
        self.rangeSpellInfoLabel = infoLabel

        -- Range update interval
        if db.rangeUpdateInterval == nil then
            db.rangeUpdateInterval = 0.5
        end
        local intervalSlider = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Range Check Interval"], 0.1, 1.0, 0.05, db, "rangeUpdateInterval", nil, function()
            if DF.SetRangeUpdateInterval then
                DF:SetRangeUpdateInterval(db.rangeUpdateInterval)
            end
        end, true), 55)
        intervalSlider.tooltip = L["How often to check range (seconds). Lower = more responsive but higher CPU. Default: 0.5s"]

        -- Frame-level alpha (shown when element-specific is disabled)
        local frameLevelAlpha = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Alpha (Out of Range)"], 0.1, 1.0, 0.05, db, "rangeFadeAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        frameLevelAlpha.hideOn = HideFrameLevelAlpha
        
        -- Element-specific toggle
        oorGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Element-Specific Alpha"], db, "oorEnabled", function()
            self:RefreshStates()
        end), 30)
        
        -- Element-specific sliders (shown when enabled)
        local oorHealth = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Health Bar Alpha"], 0.0, 1.0, 0.05, db, "oorHealthBarAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorHealth.disableOn = HideOOROptions
        
        local oorMissingHealth = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Missing Health Alpha"], 0.0, 1.0, 0.05, db, "oorMissingHealthAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorMissingHealth.disableOn = HideOOROptions

        local oorBg = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Background Alpha"], 0.0, 1.0, 0.05, db, "oorBackgroundAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorBg.disableOn = HideOOROptions

        local oorBorder = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Border Alpha"], 0.0, 1.0, 0.05, db, "oorBorderAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorBorder.disableOn = HideOOROptions

        -- Unified Text Alpha: the Text Designer now renders all unit text, so a
        -- single OOR alpha dims every TD text element (name/health/power/custom)
        -- out of range — replacing the old per-element Name/Health text alphas.
        local oorText = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Text Alpha"], 0.0, 1.0, 0.05, db, "oorTextAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorText.disableOn = HideOOROptions

        local oorAuras = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Auras Alpha"], 0.0, 1.0, 0.05, db, "oorAurasAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorAuras.disableOn = HideOOROptions
        
        local oorIcons = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Icons Alpha"], 0.0, 1.0, 0.05, db, "oorIconsAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorIcons.disableOn = HideOOROptions
        
        local oorDispel = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Dispel Overlay Alpha"], 0.0, 1.0, 0.05, db, "oorDispelOverlayAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorDispel.disableOn = HideOOROptions
        
        -- My Buff Indicator OOR slider removed — feature deprecated

        local oorPower = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Power Bar Alpha"], 0.0, 1.0, 0.05, db, "oorPowerBarAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorPower.disableOn = HideOOROptions
        
        local oorMissingBuff = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Missing Buff Alpha"], 0.0, 1.0, 0.05, db, "oorMissingBuffAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorMissingBuff.disableOn = HideOOROptions
        
        local oorDefensive = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Defensive Icon Alpha"], 0.0, 1.0, 0.05, db, "oorDefensiveIconAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorDefensive.disableOn = HideOOROptions
        
        local oorTargetedSpell = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Targeted Spell Alpha"], 0.0, 1.0, 0.05, db, "oorTargetedSpellAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorTargetedSpell.disableOn = HideOOROptions

        local oorAuraDesigner = oorGroup:AddWidget(GUI:CreateSlider(self.child, L["Aura Designer Alpha"], 0.0, 1.0, 0.05, db, "oorAuraDesignerAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorAuraDesigner.disableOn = HideOOROptions

        Add(oorGroup, nil, 1)
        
        -- ===== DEAD/OFFLINE FADING GROUP (Column 2) =====
        local deadGroup = GUI:CreateSettingsGroup(self.child, 280)
        deadGroup:AddWidget(GUI:CreateHeader(self.child, L["Dead/Offline Fading"]), 40)
        
        local deadFadeEnable = deadGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Dead Fade"], db, "fadeDeadFrames", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)
        deadFadeEnable.keepEnabled = true
        deadGroup.disableChildrenOn = function(d) return not d.fadeDeadFrames end

        -- Sliders grey out (disabled-in-place) via deadGroup.disableChildrenOn above.
        deadGroup:AddWidget(GUI:CreateSlider(self.child, L["Background Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadBackground", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadGroup:AddWidget(GUI:CreateSlider(self.child, L["Health Bar Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadHealthBar", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadGroup:AddWidget(GUI:CreateSlider(self.child, L["Name Text Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadName", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadGroup:AddWidget(GUI:CreateSlider(self.child, L["Power Bar Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadPowerBar", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadGroup:AddWidget(GUI:CreateSlider(self.child, L["Icons Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadIcons", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadGroup:AddWidget(GUI:CreateSlider(self.child, L["Auras Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadAuras", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadGroup:AddWidget(GUI:CreateSlider(self.child, L["Status Text Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadStatusText", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)

        deadGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Custom Dead Background"], db, "fadeDeadUseCustomColor", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)

        -- Colour picker also greys on the useCustomColor variant (disableOn composes
        -- with the group's enable gate).
        local deadBgColor = deadGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Dead Background Color"], db, "fadeDeadBackgroundColor", false, function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 35)
        deadBgColor.disableOn = function(d) return not d.fadeDeadUseCustomColor end
        
        Add(deadGroup, nil, 2)
        
        -- ===== HEALTH THRESHOLD FADING (above health threshold) =====
        AddSpace(20, "both")
        local hfGroup = GUI:CreateSettingsGroup(self.child, 560)
        hfGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Threshold Fading"]), 40)
        hfGroup.tooltip = L["Fade frames or elements when a unit's health is above the set threshold (e.g. 100% or 80%)."]

        local hfEnable = hfGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Health Threshold Fade"], db, "healthFadeEnabled", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)
        hfEnable.keepEnabled = true
        hfGroup.disableChildrenOn = function(d) return not d.healthFadeEnabled end

        local hfThreshold = hfGroup:AddWidget(GUI:CreateSlider(self.child, L["Health Threshold (%)"], 50, 100, 1, db, "healthFadeThreshold", function()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 55)
        hfThreshold.tooltip = L["Units at or above this health percent are faded."]

        local hfCancelDispel = hfGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Cancel Fade on Dispellable Debuff"], db, "hfCancelOnDispel", function()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)

        -- Health fade sliders need UpdateAllFrameAppearances to force an immediate visual refresh.
        -- Unlike OOR/dead fade which refresh on range/state changes, health fade alpha values
        -- are only re-read during appearance updates, not triggered by FullFrameRefresh alone.
        local function RefreshHealthFade()
            if DF.InvalidateHealthFadeCurve then DF:InvalidateHealthFadeCurve() end
            DF:RefreshAllVisibleFrames()
            if DF.UpdateAllFrameAppearances then DF:UpdateAllFrameAppearances() end
        end

        local hfFrameAlpha = hfGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Alpha (Above Threshold)"], 0.1, 1.0, 0.05, db, "healthFadeAlpha", nil, RefreshHealthFade, true), 55)
        hfFrameAlpha.tooltip = L["Frame opacity when health is above the threshold."]

        Add(hfGroup, nil, "both")
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "display_visibility", label = L["Visibility"]},
            -- LEGACY-TEXT-CLEANUP: legacy text page hidden; link removed
            -- {pageId = "text_status", label = L["Status Text"]},
        }), 30, "both")
    end)
    
    -- Display > Pet Frames
    local pagePets = CreateSubTab("display", "display_pets", L["Pet Frames"])
    BuildPage(pagePets, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right
        Add(CreateCopyButton(self.child, {"pet"}, L["Pet Frames"], "display_pets"), 25, 2)
        
        -- Check modes for conditional content
        local isGroupedMode = db.petGroupMode == "GROUPED"
        local isRaidMode = GUI.SelectedMode == "raid"
        
        -- ===== GENERAL GROUP (full width) =====
        local generalGroup = GUI:CreateSettingsGroup(self.child, 560)
        generalGroup:AddWidget(GUI:CreateHeader(self.child, L["Pet Frame Settings"]), 40)
        local petEnable = generalGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Pet Frames"], db, "petEnabled", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            self:RefreshStates()
        end), 30)
        petEnable.keepEnabled = true
        generalGroup.disableChildrenOn = function(d) return not d.petEnabled end
        generalGroup:AddWidget(GUI:CreateLabel(self.child, L["Show health bars for player and party/raid member pets, anchored to their owner's frame. Pet frames hide when owner dies."], 530), 30)
        Add(generalGroup, nil, "both")
        
        -- ===== LAYOUT MODE GROUP (full width) =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 560)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout Mode"]), 40)
        layoutGroup.disableChildrenOn = function(d) return not d.petEnabled end
        
        local groupModeValues = {
            ATTACHED = L["Attached to Owner"],
            GROUPED = L["Separate Pet Group"],
        }
        layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Layout Mode"], groupModeValues, db, "petGroupMode", function()
            if DF.UpdateAllPetFrames then DF:UpdateAllPetFrames(true) end
            if DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
            GUI:RefreshCurrentPage()
        end), 55)
        
        if not isGroupedMode then
            layoutGroup:AddWidget(GUI:CreateLabel(self.child, L["Pet frames are positioned relative to their owner's frame."], 530), 25)
        else
            layoutGroup:AddWidget(GUI:CreateLabel(self.child, L["Pet frames are grouped together in a separate container."], 530), 25)
        end
        Add(layoutGroup, nil, "both")
        
        -- ===== COLUMN 1 GROUPS =====
        
        -- GROUPED MODE: Group Settings (col1)
        if isGroupedMode then
            local groupedSettingsGroup = GUI:CreateSettingsGroup(self.child, 280)
            groupedSettingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Group Settings"]), 40)
            groupedSettingsGroup.disableChildrenOn = function(d) return not d.petEnabled end
            
            local groupAnchorValues = {
                BOTTOM = isRaidMode and L["Below Raid"] or L["Below Party"],
                TOP = isRaidMode and L["Above Raid"] or L["Above Party"],
                LEFT = isRaidMode and L["Left of Raid"] or L["Left of Party"],
                RIGHT = isRaidMode and L["Right of Raid"] or L["Right of Party"],
            }
            local updateFunc = isRaidMode 
                and function() if DF.UpdateRaidPetGroupLayout then DF:UpdateRaidPetGroupLayout() end end
                or function() if DF.UpdatePetGroupLayout then DF:UpdatePetGroupLayout() end end
            
            groupedSettingsGroup:AddWidget(GUI:CreateDropdown(self.child, L["Group Position"], groupAnchorValues, db, "petGroupAnchor", updateFunc), 55)
            
            local growthValues = { HORIZONTAL= L["Horizontal"], VERTICAL= L["Vertical"] }
            groupedSettingsGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growthValues, db, "petGroupGrowth", updateFunc), 55)
            groupedSettingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing"], 0, 20, 1, db, "petGroupSpacing", updateFunc, updateFunc, true), 55)
            groupedSettingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Group X Offset"], -100, 100, 1, db, "petGroupOffsetX", updateFunc, updateFunc, true), 55)
            groupedSettingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Group Y Offset"], -100, 100, 1, db, "petGroupOffsetY", updateFunc, updateFunc, true), 55)
            
            if isRaidMode then
                groupedSettingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Group Label"], db, "petGroupShowLabel", function()
                    if DF.UpdateRaidPetGroupLayout then DF:UpdateRaidPetGroupLayout() end
                end), 30)
            end
            
            Add(groupedSettingsGroup, nil, 1)
        end
        
        -- SIZE GROUP (col1)
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Size"]), 40)
        sizeGroup.disableChildrenOn = function(d) return not d.petEnabled end
        
        if not isGroupedMode then
            sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Match Owner Width"], db, "petMatchOwnerWidth", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
                GUI:RefreshCurrentPage()
            end), 30)
            sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Match Owner Height"], db, "petMatchOwnerHeight", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
                GUI:RefreshCurrentPage()
            end), 30)
        end
        
        local widthSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Width"], 40, 150, 1, db, "petFrameWidth", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        if not isGroupedMode then
            widthSlider.disableOn = function(d) return d.petMatchOwnerWidth end
        end
        
        local heightSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Height"], 10, 40, 1, db, "petFrameHeight", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        if not isGroupedMode then
            heightSlider.disableOn = function(d) return d.petMatchOwnerHeight end
        end
        
        Add(sizeGroup, nil, 1)
        
        -- HEALTH BAR GROUP (col1)
        local healthBarGroup = GUI:CreateSettingsGroup(self.child, 280)
        healthBarGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Bar"]), 40)
        healthBarGroup.disableChildrenOn = function(d) return not d.petEnabled end
        
        local healthColorValues = {
            GREEN = L["Always Green"],
            CLASS = L["Class Color"],
            HEALTH = L["Health Gradient"],
            CUSTOM = L["Custom Color"],
        }
        healthBarGroup:AddWidget(GUI:CreateDropdown(self.child, L["Health Bar Color"], healthColorValues, db, "petHealthColorMode", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            GUI:RefreshCurrentPage()
        end), 55)
        
        local customHealthColor = healthBarGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Custom Health Color"], db, "petHealthColor", false, function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        customHealthColor.hideOn = function(d) return d.petHealthColorMode ~= "CUSTOM" end
        
        healthBarGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Health Percentage"], db, "petShowHealthText", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end), 30)

        healthBarGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Power Bar"], db, "petShowPowerBar", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            GUI:RefreshCurrentPage()
        end), 30)

        local petPowerHeight = healthBarGroup:AddWidget(GUI:CreateSlider(self.child, L["Power Bar Height"], 1, 12, 1, db, "petPowerBarHeight", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        petPowerHeight.disableOn = function(d) return not d.petShowPowerBar end  -- grey when power bar off

        local powerColorValues = {
            POWER = L["By Power Type"],
            CUSTOM = L["Custom Color"],
        }
        local petPowerColorMode = healthBarGroup:AddWidget(GUI:CreateDropdown(self.child, L["Power Bar Color"], powerColorValues, db, "petPowerColorMode", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            GUI:RefreshCurrentPage()
        end), 55)
        petPowerColorMode.disableOn = function(d) return not d.petShowPowerBar end  -- grey when power bar off

        local customPowerColor = healthBarGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Custom Power Color"], db, "petPowerColor", false, function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        -- Grey when the power bar is off (boolean fold); HIDE only for the non-CUSTOM
        -- colour mode (variant gating). The two compose: hidden in non-CUSTOM, greyed
        -- in CUSTOM while the power bar is off.
        customPowerColor.disableOn = function(d) return not d.petShowPowerBar end
        customPowerColor.hideOn = function(d) return d.petPowerColorMode ~= "CUSTOM" end

        Add(healthBarGroup, nil, 1)
        
        -- NAME TEXT GROUP (col1)
        local textAnchorValues = {
            TOPLEFT= L["Top Left"], TOP= L["Top"], TOPRIGHT= L["Top Right"],
            LEFT= L["Left"], CENTER= L["Center"], RIGHT= L["Right"],
            BOTTOMLEFT= L["Bottom Left"], BOTTOM= L["Bottom"], BOTTOMRIGHT= L["Bottom Right"],
        }
        
        local nameTextGroup = GUI:CreateSettingsGroup(self.child, 280)
        nameTextGroup:AddWidget(GUI:CreateHeader(self.child, L["Name Text"]), 40)
        nameTextGroup.disableChildrenOn = function(d) return not d.petEnabled end
        nameTextGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "petNameFont", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        nameTextGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 16, 1, db, "petNameFontSize", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        nameTextGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "petNameFontOutline", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        nameTextGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "petNameFontOutline", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 30)
        nameTextGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Name Length"], 4, 20, 1, db, "petNameMaxLength", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end), 55)
        nameTextGroup:AddWidget(GUI:CreateDropdown(self.child, L["Name Anchor"], textAnchorValues, db, "petNameAnchor", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        nameTextGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Name Text Color"], db, "petNameColor", false, function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        nameTextGroup:AddWidget(GUI:CreateSlider(self.child, L["Name X Offset"], -30, 30, 1, db, "petNameX", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        nameTextGroup:AddWidget(GUI:CreateSlider(self.child, L["Name Y Offset"], -15, 15, 1, db, "petNameY", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        Add(nameTextGroup, nil, 1)
        
        -- ===== COLUMN 2 GROUPS =====
        
        -- POSITION GROUP (col2, Attached mode only)
        if not isGroupedMode then
            local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
            positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
            positionGroup.disableChildrenOn = function(d) return not d.petEnabled end

            local anchorValues = {
                BOTTOM = L["Below Owner"],
                TOP = L["Above Owner"],
                LEFT = L["Left of Owner"],
                RIGHT = L["Right of Owner"],
            }
            positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorValues, db, "petAnchor", function()
                if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end
            end), 55)
            positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "petOffsetX", function()
                if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end
            end, function() if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end end, true), 55)
            positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "petOffsetY", function()
                if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end
            end, function() if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end end, true), 55)
            
            Add(positionGroup, nil, 2)
        end
        
        -- APPEARANCE GROUP (col2)
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        appearanceGroup.disableChildrenOn = function(d) return not d.petEnabled end
        appearanceGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Health Bar Texture"], db, "petTexture", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        appearanceGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "petBackgroundColor", true, function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        Add(appearanceGroup, nil, 2)

        -- ===== BORDER GROUP (Stage 4.3) =====
        -- include set tailored for a mini unit frame's border. Skipped:
        -- animate (decoration, not alert), offset (Pet Frame has its own
        -- Offset X / Y in the Position group above), class / role colour
        -- (UnitClass("pet") returns the pet family, not a class token),
        -- colour-by-time / colour-by-type (no aura-state context).
        local petBorderGroup = GUI:CreateSettingsGroup(self.child, 280)
        petBorderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        petBorderGroup.disableChildrenOn = function(d) return not d.petEnabled end
        GUI:CreateBorderControls(petBorderGroup, db, "pet", {
            parent       = self.child,
            include      = { alpha = true, inset = true, blendMode = true,
                             gradient = true, shadow = true },
            fullUpdate   = function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end,
            lightUpdate  = function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end,
            lightColors  = function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end,
            refreshStates = function() self:RefreshStates() end,
            sizeMin = 1, sizeMax = 6, sizeStep = 1,
        })
        Add(petBorderGroup, nil, 1)
        
        -- HEALTH TEXT GROUP (col2)
        local healthTextGroup = GUI:CreateSettingsGroup(self.child, 280)
        healthTextGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Text"]), 40)
        healthTextGroup.disableChildrenOn = function(d) return not d.petEnabled end
        healthTextGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "petHealthFont", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        healthTextGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 14, 1, db, "petHealthFontSize", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        healthTextGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "petHealthFontOutline", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        healthTextGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "petHealthFontOutline", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 30)
        healthTextGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Health Text Color"], db, "petHealthTextColor", false, function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        healthTextGroup:AddWidget(GUI:CreateDropdown(self.child, L["Health Text Anchor"], textAnchorValues, db, "petHealthAnchor", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        healthTextGroup:AddWidget(GUI:CreateSlider(self.child, L["Health X Offset"], -30, 30, 1, db, "petHealthX", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        healthTextGroup:AddWidget(GUI:CreateSlider(self.child, L["Health Y Offset"], -15, 15, 1, db, "petHealthY", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        Add(healthTextGroup, nil, 2)
    end)
    
    -- General > Settings (mode enable/disable, Blizzard frame toggles, profile-wide settings)
    local pageGeneral = CreateSubTab("general", "general_settings", L["Settings"])
    BuildPage(pageGeneral, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Helpers: read from party-mode storage (canonical), write to BOTH
        -- party and raid mode dbs so the value stays consistent regardless
        -- of which mode is currently selected. The Blizzard frames are
        -- global UI elements so the toggle conceptually has no mode.
        local function makeBlizGet(key)
            return function() return DF.db.party and DF.db.party[key] end
        end
        local function makeBlizSet(key, cb)
            return function(val)
                if DF.db.party then DF.db.party[key] = val end
                if DF.db.raid  then DF.db.raid[key]  = val end
                if cb then cb() end
            end
        end

        -- Contextual reload popup shown when toggling DF Party/Raid frames.
        -- Offers an optional third button that ALSO flips the matching
        -- Blizzard hide flag, so "enabling" DF party also disables Blizzard
        -- party (typical intent) and "disabling" DF party also enables
        -- Blizzard party (so the user isn't left with no frames).
        local function PromptReloadAfterModeToggle(mode)
            if not DF:EnableFlagsDifferFromLoaded() then return end
            if not DF.ShowPopupAlert then return end

            -- NB: don't use `cond and a or b` here — the `a` result can be
            -- false (when DF frames are disabled), which makes the `or`
            -- fall through to the wrong mode's value.
            local enabled
            if mode == "party" then
                enabled = DF.db.partyEnabled ~= false
            else
                enabled = DF.db.raidEnabled ~= false
            end
            local blizKey = (mode == "party") and "hideBlizzardPartyFrames" or "hideBlizzardRaidFrames"
            local blizCurrentlyHidden = DF.db.party and DF.db.party[blizKey]

            local buttons = {}
            if enabled and not blizCurrentlyHidden then
                -- Enabling DF frames while Blizzard frames are still visible
                -- → offer to disable the Blizzard equivalent on the same reload
                buttons[#buttons + 1] = {
                    label = (mode == "party") and L["Reload & Disable Blizzard Party"] or L["Reload & Disable Blizzard Raid"],
                    onClick = function()
                        if DF.db.party then DF.db.party[blizKey] = true end
                        if DF.db.raid  then DF.db.raid[blizKey]  = true end
                        ReloadUI()
                    end,
                }
            elseif (not enabled) and blizCurrentlyHidden then
                -- Disabling DF frames while Blizzard frames are hidden
                -- → offer to re-enable the Blizzard equivalent
                buttons[#buttons + 1] = {
                    label = (mode == "party") and L["Reload & Enable Blizzard Party"] or L["Reload & Enable Blizzard Raid"],
                    onClick = function()
                        if DF.db.party then DF.db.party[blizKey] = false end
                        if DF.db.raid  then DF.db.raid[blizKey]  = false end
                        ReloadUI()
                    end,
                }
            end
            buttons[#buttons + 1] = { label = L["Just Reload"], onClick = function() ReloadUI() end }
            buttons[#buttons + 1] = { label = L["Reload Later"] }

            DF:ShowPopupAlert({
                title = L["Reload Required"],
                message = L["Enabling or disabling a frame mode requires a UI reload to take effect.\n\nReload now?"],
                width = 560,
                buttonWidth = 170,
                buttonHeight = 44,
                buttons = buttons,
            })
        end

        -- ===== INFO BANNER (global settings notice) =====
        do
            local banner = GUI:CreateInfoBanner(self.child, {
                tone = "info",
                text = L["Settings on this page apply globally — changes persist across both the Party and Raid sections."],
            })
            Add(banner, banner.layoutHeight, "both")
        end

        -- ===== FRAME MODES GROUP (Column 1, Top) =====
        local modesGroup = GUI:CreateSettingsGroup(self.child, 280)
        modesGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Modes"]), 40)
        modesGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Party Frames"], DF.db, "partyEnabled", function() PromptReloadAfterModeToggle("party") end), 30)
        modesGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Raid Frames"], DF.db, "raidEnabled", function() PromptReloadAfterModeToggle("raid") end), 30)
        modesGroup:AddWidget(GUI:CreateLabel(self.child,
            L["Completely enable or disable the Party or Raid frame system. Disabled modes are never created, consuming zero performance in the background. Requires a UI reload to apply."],
            260), 80)
        Add(modesGroup, nil, 1)

        -- ===== BLIZZARD FRAMES GROUP (Column 1, Bottom) =====
        -- Storage stays per-mode (party + raid both updated via setter sync)
        -- so AutoProfiles and ExportCategories continue to work unchanged.
        local blizzardGroup = GUI:CreateSettingsGroup(self.child, 280)
        blizzardGroup:AddWidget(GUI:CreateHeader(self.child, L["Blizzard Frames"]), 40)

        local disablePartyCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(
            self.child, L["Disable Blizzard Party Frames"],
            DF.db.party, "hideBlizzardPartyFrames",
            function() DF:UpdateBlizzardFrameVisibility() end,
            makeBlizGet("hideBlizzardPartyFrames"),
            makeBlizSet("hideBlizzardPartyFrames", function() DF:UpdateBlizzardFrameVisibility() end)
        ), 30)
        disablePartyCheck.tooltip = L["Hides and unregisters all events on the default Blizzard party frames so they consume no performance."]

        local disableRaidCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(
            self.child, L["Disable Blizzard Raid Frames"],
            DF.db.party, "hideBlizzardRaidFrames",
            function() DF:UpdateBlizzardFrameVisibility() end,
            makeBlizGet("hideBlizzardRaidFrames"),
            makeBlizSet("hideBlizzardRaidFrames", function() DF:UpdateBlizzardFrameVisibility() end)
        ), 30)
        disableRaidCheck.tooltip = L["Hides and unregisters all events on the default Blizzard raid frames so they consume no performance."]

        local disablePlayerCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(
            self.child, L["Hide Blizzard Player Frame"],
            nil, nil,
            function() DF:UpdateDefaultPlayerFrame() end,
            makeBlizGet("hideDefaultPlayerFrame"),
            makeBlizSet("hideDefaultPlayerFrame", function() DF:UpdateDefaultPlayerFrame() end),
            "hideDefaultPlayerFrame"
        ), 30)
        disablePlayerCheck.tooltip = L["Hides the default Blizzard player portrait and health bar."]

        -- Visual divider + small caption to separate the related sub-option
        -- (Show Side Menu only applies once a Blizzard frame is disabled)
        local divider = CreateFrame("Frame", nil, self.child)
        divider:SetSize(260, 1)
        local dividerTex = divider:CreateTexture(nil, "OVERLAY")
        dividerTex:SetColorTexture(1, 1, 1, 0.08)
        dividerTex:SetPoint("LEFT", 0, 0)
        dividerTex:SetPoint("RIGHT", 0, 0)
        dividerTex:SetHeight(1)
        blizzardGroup:AddWidget(divider, 14)

        local sideMenuCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(
            self.child, L["Show Party/Raid Side Menu"],
            DF.db.party, "showBlizzardSideMenu",
            function() DF:UpdateBlizzardFrameVisibility() end,
            makeBlizGet("showBlizzardSideMenu"),
            makeBlizSet("showBlizzardSideMenu", function() DF:UpdateBlizzardFrameVisibility() end)
        ), 30)
        sideMenuCheck.disableOn = function()
            local p = DF.db.party
            return not (p and (p.hideBlizzardPartyFrames or p.hideBlizzardRaidFrames))
        end
        sideMenuCheck.tooltip = L["Shows the ping wheel & party management menu when Blizzard frames are disabled."]

        Add(blizzardGroup, nil, 1)

        -- ===== MINIMAP GROUP (Column 1) =====
        -- The minimap button is a single global UI element (no mode), so it lives
        -- here rather than the per-mode Visibility page. Reads party-canonical and
        -- writes both dbs so it stays consistent regardless of selected mode.
        local minimapGroup = GUI:CreateSettingsGroup(self.child, 280)
        minimapGroup:AddWidget(GUI:CreateHeader(self.child, L["Minimap"]), 40)
        minimapGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Minimap Button"], nil, nil, function()
            DF:UpdateMinimapButton()
        end, makeBlizGet("showMinimapButton"), makeBlizSet("showMinimapButton"), "showMinimapButton"), 30)
        Add(minimapGroup, nil, 1)

        -- ===== RENDERING GROUP (Column 1) =====
        -- Pixel-Perfect Scaling is a render-quality flag read by every frame and
        -- element in BOTH modes (Frames/Core.lua GetPixelScale + 60-odd db.pixelPerfect
        -- reads), so it's global — read party-canonical, write both mode dbs (same
        -- pattern as the Blizzard/Minimap toggles above) — and lives here rather than
        -- on the per-mode Frame page.
        local function refreshPixelPerfect()
            -- Re-apply header sizing + refresh the live frames (UpdateAllFrames auto-
            -- routes party vs raid by the real in-world context) plus any test frames.
            if DF.headersInitialized and DF.ApplyHeaderSettings then DF:ApplyHeaderSettings() end
            if DF.UpdateAllFrames then DF:UpdateAllFrames() end
            if (DF.testMode or DF.raidTestMode) and DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
        end
        local renderingGroup = GUI:CreateSettingsGroup(self.child, 280)
        renderingGroup:AddWidget(GUI:CreateHeader(self.child, L["Rendering"]), 40)
        renderingGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Pixel-Perfect Scaling"],
            nil, nil, refreshPixelPerfect,
            makeBlizGet("pixelPerfect"), makeBlizSet("pixelPerfect"), "pixelPerfect"), 30)
        renderingGroup:AddWidget(GUI:CreateLabel(self.child,
            L["Snaps sizes and borders to exact pixels for crisp rendering."], 250), 30)
        -- Pixel-perfect scale hint: at a UI Scale of 768/physicalHeight, one UI unit
        -- equals one physical pixel, so snapping has nothing to round away and borders
        -- are at their crispest. Tell the user that value (and whether they're already
        -- there) — purely informational, we never change their scale for them.
        do
            local function computeScaleHint()
                local _, physH = GetPhysicalScreenSize()
                local recScale = (physH and physH > 0) and (768 / physH) or 1
                local pp = (DF.GetPixelScale and DF:GetPixelScale()) or 1
                if math.abs(pp - 1) < 0.01 then
                    return L["Your UI Scale is already pixel-perfect for this resolution."]
                end
                return string.format(
                    L["Tip: for the crispest result at this resolution, set your UI Scale to %.4f — type /console UIScale %.4f to apply it (it may be below the in-game slider's minimum)."],
                    recScale, recScale)
            end
            local scaleHint = GUI:CreateLabel(self.child, computeScaleHint(), 250)
            -- Recompute on page refresh so the hint isn't stale after a resolution or
            -- UI-scale change (GetPixelScale is re-cached on those events). Idempotent
            -- SetText — only writes when the text actually changed — so no relayout loop.
            scaleHint.refreshContent = function()
                local t = computeScaleHint()
                if t ~= scaleHint._dfLastHint then
                    scaleHint._dfLastHint = t
                    scaleHint:SetText(t)
                end
            end
            renderingGroup:AddWidget(scaleHint, 45)
        end
        Add(renderingGroup, nil, 1)

        -- ===== SETTINGS PANEL APPEARANCE GROUP (Column 2, Top) =====
        -- Controls the look of this settings panel itself — does NOT affect
        -- in-game frame text (use Health Text / Name Text pages for those).
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings Panel Appearance"]), 40)
        appearanceGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Settings Font"], DF.db, "settingsFont", function()
            if GUI.RefreshSettingsFont then GUI:RefreshSettingsFont() end
        end), 55)
        appearanceGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Settings Font Outline"], DF.db, "settingsFontOutline", function()
            if GUI.RefreshSettingsFont then GUI:RefreshSettingsFont() end
        end), 55)
        appearanceGroup:AddWidget(GUI:CreateLabel(self.child,
            L["Font used for this settings panel. Does not affect in-game frame text — use the Text Designer for those."],
            260), 60)
        Add(appearanceGroup, nil, 2)

        -- ===== LANGUAGE GROUP (Column 2, Bottom) =====
        local languageValues = {
            AUTO  = L["Auto (use client language)"],
            enUS  = "English",
            deDE  = "Deutsch",
            esES  = "Español (ES)",
            esMX  = "Español (MX)",
            frFR  = "Français",
            itIT  = "Italiano",
            koKR  = "한국어",
            ptBR  = "Português (BR)",
            ruRU  = "Русский",
            zhCN  = "中文 (简体)",
            zhTW  = "中文 (繁體)",
        }
        local languageGroup = GUI:CreateSettingsGroup(self.child, 280)
        languageGroup:AddWidget(GUI:CreateHeader(self.child, L["Language"]), 40)
        -- Language override lives on the per-character SavedVariable so
        -- locale files can read it at file-load time (before DF.db exists).
        languageGroup:AddWidget(GUI:CreateDropdown(self.child, L["Addon Language"], languageValues, DandersFramesCharDB, "languageOverride", function()
            if DF.ShowPopupAlert then
                DF:ShowPopupAlert({
                    title = L["Reload Required"],
                    message = L["Changing the addon language requires a UI reload to take effect.\n\nReload now?"],
                    buttons = {
                        { label = L["Reload Now"], onClick = function() ReloadUI() end },
                        { label = L["Later"] },
                    },
                })
            end
        end), 55)
        languageGroup:AddWidget(GUI:CreateLabel(self.child,
            L["Override the addon's display language. Auto follows your WoW client language. Translations are community-contributed and may be incomplete."],
            260), 60)
        Add(languageGroup, nil, 2)

        -- ===== NOTIFICATIONS GROUP (Column 2, Bottom) =====
        local notificationsGroup = GUI:CreateSettingsGroup(self.child, 280)
        notificationsGroup:AddWidget(GUI:CreateHeader(self.child, L["Notifications"]), 40)
        notificationsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Notify me when a newer version is available"],
            DF:GetGlobalDB(), "notifyOutdated", function()
                -- Setting applies immediately; no extra callback needed.
            end), 30)
        Add(notificationsGroup, nil, 2)
    end)

    -- General > Frame
    local pageFrame = CreateSubTab("general", "general_frame", L["Frame"])
    BuildPage(pageFrame, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"frame", "background", "missingHealth", "border", "anchor"}, L["Frame"], "general_frame"), 25, 2)
        
        -- Migration: Ensure new flat raid settings have defaults
        if db.raidFlatGrowthAnchor == nil then db.raidFlatGrowthAnchor = "START" end
        if db.raidFlatFrameAnchor == nil then db.raidFlatFrameAnchor = "START" end
        if db.raidFlatColumnAnchor == nil then db.raidFlatColumnAnchor = "START" end
        
        -- Function to update the correct frames based on mode
        local function UpdateFrames()
            -- Invalidate the raid layoutSig optimization cache BEFORE
            -- ApplyHeaderSettings runs, so this cycle's ApplyRaidGroupSorting
            -- applies layout settings that aren't tracked by layoutSig (notably
            -- raidGroupRowGrowth) instead of bailing. (PR #134)
            if GUI.SelectedMode == "raid" then
                DF._lastRaidLayoutSig = nil
                DF._raidSortApplied   = false
            end
            if DF.headersInitialized then
                DF:ApplyHeaderSettings()
            end
            if GUI.SelectedMode == "raid" then
                DF:UpdateRaidLayout()
                if DF.SecureSort and DF.SecureSort.raidFramesRegistered then
                    DF.SecureSort:PushRaidLayoutConfig()
                    DF.SecureSort:PushRaidGroupLayoutConfig()
                    DF.SecureSort:TriggerSecureRaidSort()
                end
                -- Update test mode frames if active
                if DF.raidTestMode then DF:UpdateRaidTestFrames() end
            else
                DF:UpdateAllFrames()
            end
        end
        
        -- Store references to sliders so we can update their labels
        local groupsPerRowSlider, rowColSpacingSlider, playersPerRowSlider
        
        -- Function to update dynamic labels based on growth direction
        local function UpdateDynamicLabels()
            if groupsPerRowSlider and groupsPerRowSlider.label then
                groupsPerRowSlider.label:SetText(db.growDirection == "VERTICAL" and L["Groups Per Column"] or L["Groups Per Row"])
            end
            if rowColSpacingSlider and rowColSpacingSlider.label then
                rowColSpacingSlider.label:SetText(db.growDirection == "VERTICAL" and L["Column Spacing"] or L["Row Spacing"])
            end
            if playersPerRowSlider and playersPerRowSlider.label then
                playersPerRowSlider.label:SetText(db.growDirection == "VERTICAL" and L["Players Per Column"] or L["Players Per Row"])
            end
        end
        
        -- Custom callback for growth direction
        local function OnGrowthDirectionChanged()
            UpdateDynamicLabels()
            UpdateFrames()
            if GUI.SelectedMode == "raid" and not db.raidUseGroups and not InCombatLockdown() then
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        if DF.headersInitialized then DF:ApplyHeaderSettings() end
                        if DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
                    end
                end)
            end
            -- Defer label repositioning so headers have settled into new direction first
            C_Timer.After(0, function()
                if DF.UpdateRaidGroupLabels then
                    DF:UpdateRaidGroupLabels()
                end
            end)
            -- Rebuild the page so orientation-dependent dropdown TITLES refresh
            -- live (e.g. "Columns Grow From" vs "Rows Grow From") without needing
            -- to reopen the settings window. Dropdowns bake their label at build
            -- time, so a rebuild is the only way to update it. (Option VALUES are
            -- now the static "Start (Left/Top)" / "End (Right/Bottom)" form, so
            -- only the titles need refreshing.) Deferred so it runs after the
            -- triggering dropdown's own click handler has finished unwinding.
            C_Timer.After(0, function()
                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            end)
        end
        
        -- ===== FRAME SIZE GROUP (Column 1) =====
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Size"]), 40)
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Width"], 60, 300, 1, db, "frameWidth", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Height"], 20, 300, 1, db, "frameHeight", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Padding"], 0, 10, 1, db, "framePadding", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Scale"], 0.5, 2.0, 0.05, db, "frameScale", function() DF:UpdateContainerPosition() DF:UpdateRaidContainerPosition() UpdateFrames() end, function() DF:LightweightUpdateFrameScale() end, true), 55)
        local frameSpacingSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Spacing"], -5, 50, 1, db, "frameSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSpacing() end, true), 55)
        frameSpacingSlider.hideOn = function() return GUI.SelectedMode == "raid" and not db.raidUseGroups end
        Add(sizeGroup, nil, 1)
        
        -- ===== APPEARANCE GROUP (Column 2) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        -- Canonical border controls via the unified helper. Replaces the
        -- previous hand-rolled Show / Color / Style / Texture / Size block.
        -- classColor + roleColor are now first-class helper include flags (no
        -- bespoke "Use Class Color" extra needed). (Pixel-Perfect Scaling moved
        -- to General > Settings > Rendering — it's a global, mode-agnostic flag.)
        GUI:CreateBorderControls(appearanceGroup, db, "frame", {
            parent       = self.child,
            include      = {
                -- Frame Border is the outer chrome of the unit. It's a
                -- structural element, not an alert surface, so animations
                -- don't fit the design — removed in Stage 4.0 after Stage
                -- 3 used it as a dev playground.
                inset = true, offset = true, blendMode = true,
                gradient = true, shadow = true,
                classColor = true, roleColor = true,
                alpha = true,
            },
            fullUpdate   = function() UpdateFrames() DF:LightweightUpdateBorder() end,
            lightUpdate  = function() DF:LightweightUpdateBorder() end,
            lightColors  = function() DF:LightweightUpdateBorderColor() end,
            refreshStates = function() if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end end,
            sizeMin = 1, sizeMax = 16, sizeStep = 1,
        })
        Add(appearanceGroup, nil, 2)

        -- ===== LAYOUT DIRECTION GROUP (Column 1) =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout Direction"]), 40)
        
        -- Party dropdown
        local partyGrowOptions = { HORIZONTAL= L["Rows"], VERTICAL= L["Columns"] }
        local partyArrangeDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], partyGrowOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
        partyArrangeDropdown.hideOn = function() return GUI.SelectedMode == "raid" end
        
        -- Raid GROUP dropdown (groups mode)
        local raidGrowOptions = { HORIZONTAL= L["Columns"], VERTICAL= L["Rows"] }
        local raidArrangeDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], raidGrowOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
        raidArrangeDropdown.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
        
        -- Raid FLAT dropdown
        local flatGrowOptions = { HORIZONTAL= L["Rows"], VERTICAL= L["Columns"] }
        local flatArrangeDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], flatGrowOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
        flatArrangeDropdown.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end
        
        -- Growth anchor (party only)
        local anchorOptions = { START= L["Start (Left/Top)"], CENTER= L["Center"], END= L["End (Right/Bottom)"] }
        local anchorDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Frames Grow From"], anchorOptions, db, "growthAnchor", UpdateFrames), 55)
        anchorDropdown.hideOn = function() return GUI.SelectedMode == "raid" end
        
        Add(layoutGroup, nil, 1)
        
        -- ===== RAID LAYOUT MODE GROUP (Column 2, raid only) =====
        local raidModeGroup = GUI:CreateSettingsGroup(self.child, 280)
        raidModeGroup:AddWidget(GUI:CreateHeader(self.child, L["Raid Layout Mode"]), 40)
        raidModeGroup.hideOn = function() return GUI.SelectedMode ~= "raid" end
        
        local useGroupsCheck = raidModeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Group-Based Layout"], db, "raidUseGroups", function()
            UpdateFrames()
            if DF.SecureSort then
                DF.SecureSort:PushRaidGroupLayoutConfig()
                DF.SecureSort:TriggerSecureRaidSort()
            end
            if not db.raidUseGroups and not InCombatLockdown() then
                if DF.UpdateRaidGroupLabels then DF:UpdateRaidGroupLabels() end
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        if DF.FlatRaidFrames then
                            if not DF.FlatRaidFrames.initialized then DF.FlatRaidFrames:Initialize() end
                            if DF.FlatRaidFrames.initialized then DF.FlatRaidFrames:SetEnabled(true) end
                        end
                        if DF.headersInitialized then DF:ApplyHeaderSettings() end
                        if DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
                    end
                end)
            else
                if DF.FlatRaidFrames and DF.FlatRaidFrames.initialized then
                    DF.FlatRaidFrames:SetEnabled(false)
                end
            end
            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
        end), 30)
        
        raidModeGroup:AddWidget(GUI:CreateLabel(self.child, L["Enabled: Players organized by raid groups (1-8).\nDisabled: All players in one flat grid."], 250), 45)
        Add(raidModeGroup, nil, 2)
        
        -- ===== GROUP LAYOUT SETTINGS (Column 1, raid+groups only) =====
        local groupLayoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        groupLayoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Group Layout Settings"]), 40)
        groupLayoutGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
        
        local groupLayoutHint = db.growDirection == "VERTICAL" and L["Players stack horizontally, groups grow top-to-bottom."] or L["Players stack vertically, groups grow left-to-right."]
        groupLayoutGroup:AddWidget(GUI:CreateLabel(self.child, groupLayoutHint, 250), 25)
        
        groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Group Spacing"], -5, 100, 1, db, "raidGroupSpacing", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
        
        local rowColLabel = db.growDirection == "VERTICAL" and L["Column Spacing"] or L["Row Spacing"]
        rowColSpacingSlider = groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, rowColLabel, -5, 100, 1, db, "raidRowColSpacing", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
        
        local groupsLabel = db.growDirection == "VERTICAL" and L["Groups Per Column"] or L["Groups Per Row"]
        groupsPerRowSlider = groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, groupsLabel, 1, 8, 1, db, "raidGroupsPerRow", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
        
        groupLayoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Group Alignment"], anchorOptions, db, "raidGroupAnchor", UpdateFrames), 55)

        local rowGrowLabel = db.growDirection == "VERTICAL" and L["Columns Grow From"] or L["Rows Grow From"]
        local rowGrowOptions = { START= L["Start (Left/Top)"], END= L["End (Right/Bottom)"] }
        groupLayoutGroup:AddWidget(GUI:CreateDropdown(self.child, rowGrowLabel, rowGrowOptions, db, "raidGroupRowGrowth", UpdateFrames), 55)

        -- Players Grow From = the direction players fill the group's main axis.
        -- HORIZONTAL groups stack players vertically (Top/Bottom); VERTICAL groups
        -- stack players horizontally (Left/Right). Values map to START/END.
        local playerAnchorOptions = { START= L["Start (Left/Top)"], END= L["End (Right/Bottom)"] }
        groupLayoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Players Grow From"], playerAnchorOptions, db, "raidPlayerAnchor", UpdateFrames), 55)
        
        Add(groupLayoutGroup, nil, 1)
        
        -- ===== GROUP VISIBILITY (Column 1, raid only) =====
        local groupVisGroup = GUI:CreateSettingsGroup(self.child, 280)
        groupVisGroup:AddWidget(GUI:CreateHeader(self.child, L["Group Visibility"]), 40)
        groupVisGroup.hideOn = function() return GUI.SelectedMode ~= "raid" end
        
        groupVisGroup:AddWidget(GUI:CreateLabel(self.child, L["Choose which groups to display."], 250), 25)
        
        -- Initialize raidGroupVisible if it doesn't exist
        if not db.raidGroupVisible then
            db.raidGroupVisible = {[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true}
        end
        
        for i = 1, 8 do
            local groupIndex = i
            local overrideKey = "raidGroupVisible_" .. i
            groupVisGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Group"] .. " " .. i, nil, nil,
                function()
                    if db.raidUseGroups then
                        -- Separated mode
                        DF:UpdateRaidHeaderVisibility(); DF:PositionRaidHeaders()
                    else
                        -- Flat mode - rebuild groupFilter and nameList
                        if DF.FlatRaidFrames then
                            DF.FlatRaidFrames:UpdateContainerSize()
                            DF.FlatRaidFrames:UpdateSorting()
                        end
                    end
                    UpdateFrames()
                end,
                function() return db.raidGroupVisible[groupIndex] ~= false end,
                function(val) db.raidGroupVisible[groupIndex] = val end,
                overrideKey
            ), 25)
        end
        
        Add(groupVisGroup, nil, 1)
        
        -- ===== GROUP DISPLAY ORDER (Column 2, raid+groups only) =====
        local groupOrderGroup = GUI:CreateSettingsGroup(self.child, 280)
        groupOrderGroup:AddWidget(GUI:CreateHeader(self.child, L["Group Display Order"]), 40)
        groupOrderGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
        
        groupOrderGroup:AddWidget(GUI:CreateLabel(self.child, L["Drag to reorder groups. Top = first."], 250), 25)
        
        local playerGroupFirstCheck = groupOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["My Group First"], db, "raidPlayerGroupFirst", function()
            if DF.UpdatePlayerGroupTracking then DF:UpdatePlayerGroupTracking() end
            if DF.UpdateRaidGroupOrderAttributes then DF:UpdateRaidGroupOrderAttributes() end
            DF:TriggerRaidPosition()
            UpdateFrames()
        end), 25)
        playerGroupFirstCheck.tooltip = L["When enabled, the group you are in will always be displayed first."]
        
        -- Initialize raidGroupDisplayOrder if it doesn't exist
        if not db.raidGroupDisplayOrder then
            db.raidGroupDisplayOrder = {1, 2, 3, 4, 5, 6, 7, 8}
        end
        
        local groupOrderWidget = GUI:CreateGroupOrderList(self.child, db, "raidGroupDisplayOrder", function()
            if DF.UpdateRaidGroupOrderAttributes then DF:UpdateRaidGroupOrderAttributes() end
            DF:TriggerRaidPosition()
            UpdateFrames()
        end)
        groupOrderGroup:AddWidget(groupOrderWidget, 230)
        
        Add(groupOrderGroup, nil, 2)
        
        -- ===== FLAT GRID SETTINGS (Column 1, raid+flat only) =====
        local flatGridGroup = GUI:CreateSettingsGroup(self.child, 280)
        flatGridGroup:AddWidget(GUI:CreateHeader(self.child, L["Flat Grid Settings"]), 40)
        flatGridGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end
        
        flatGridGroup:AddWidget(GUI:CreateLabel(self.child, L["All players in a unified grid. Sorting applies raid-wide."], 250), 25)
        
        local function UpdateFlatLayoutFull()
            if InCombatLockdown() then return end
            if DF.headersInitialized then DF:ApplyHeaderSettings() end
            if GUI.SelectedMode == "raid" then DF:UpdateRaidLayout() end
        end
        
        local playersPerLabel = db.growDirection == "VERTICAL" and L["Players Per Column"] or L["Players Per Row"]
        playersPerRowSlider = flatGridGroup:AddWidget(GUI:CreateSlider(self.child, playersPerLabel, 1, 40, 1, db, "raidPlayersPerRow", UpdateFlatLayoutFull, UpdateFlatLayoutFull, true), 55)
        
        local growthAnchorOptions = { START= L["Start (Left/Top)"], CENTER= L["Center"], END= L["End (Right/Bottom)"] }
        flatGridGroup:AddWidget(GUI:CreateDropdown(self.child, L["Grid Alignment"], growthAnchorOptions, db, "raidFlatGrowthAnchor", UpdateFrames), 55)

        -- Columns/Rows Grow From = the direction the grid wraps (secondary axis).
        -- VERTICAL (Columns) wraps left/right; HORIZONTAL (Rows) wraps top/bottom.
        local flatColumnLabel = db.growDirection == "VERTICAL" and L["Columns Grow From"] or L["Rows Grow From"]
        local flatColumnOptions = { START= L["Start (Left/Top)"], END= L["End (Right/Bottom)"] }
        flatGridGroup:AddWidget(GUI:CreateDropdown(self.child, flatColumnLabel, flatColumnOptions, db, "raidFlatColumnAnchor", UpdateFrames), 55)

        -- Players Grow From = the direction players fill the grid's main axis.
        -- HORIZONTAL (Rows) fills Left/Right; VERTICAL (Columns) fills Top/Bottom.
        -- Replaces the old "Reverse Order" checkbox; START/END values are identical.
        local flatFillOptions = { START= L["Start (Left/Top)"], END= L["End (Right/Bottom)"] }
        flatGridGroup:AddWidget(GUI:CreateDropdown(self.child, L["Players Grow From"], flatFillOptions, db, "raidFlatFrameAnchor", UpdateFrames), 55)
        
        flatGridGroup:AddWidget(GUI:CreateSlider(self.child, L["Horizontal Spacing"], -5, 100, 1, db, "raidFlatHorizontalSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        flatGridGroup:AddWidget(GUI:CreateSlider(self.child, L["Vertical Spacing"], -5, 100, 1, db, "raidFlatVerticalSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        
        Add(flatGridGroup, nil, 1)
        
        -- Update labels on show
        if groupsPerRowSlider and groupsPerRowSlider.label then
            groupsPerRowSlider:HookScript("OnShow", UpdateDynamicLabels)
        end
        if rowColSpacingSlider and rowColSpacingSlider.label then
            rowColSpacingSlider:HookScript("OnShow", UpdateDynamicLabels)
        end
        if playersPerRowSlider and playersPerRowSlider.label then
            playersPerRowSlider:HookScript("OnShow", UpdateDynamicLabels)
        end

        -- ===== PERMANENT MOVER GROUP (Column 2) =====
        local permMoverGroup = GUI:CreateSettingsGroup(self.child, 280)
        permMoverGroup:AddWidget(GUI:CreateHeader(self.child, L["Permanent Mover"]), 40)

        permMoverGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Permanent Mover"], db, "permanentMover", function()
            DF:UpdatePermanentMoverVisibility()
        end), 30)

        local moverAnchorValues = {
            TOPLEFT= L["Top Left"], TOP= L["Top"], TOPRIGHT= L["Top Right"],
            LEFT= L["Left"], RIGHT= L["Right"],
            BOTTOMLEFT= L["Bottom Left"], BOTTOM= L["Bottom"], BOTTOMRIGHT= L["Bottom Right"],
        }
        local permMoverAnchor = permMoverGroup:AddWidget(
            GUI:CreateDropdown(self.child, L["Handle Position"], moverAnchorValues, db, "permanentMoverAnchor", function()
                DF:UpdatePermanentMoverAnchor(GUI.SelectedMode)
            end), 55)
        permMoverAnchor.disableOn = function(d) return not d.permanentMover end

        local attachValues = { CONTAINER= L["Container"], FIRST= L["First Unit"], LAST= L["Last Unit"] }
        local permAttach = permMoverGroup:AddWidget(
            GUI:CreateDropdown(self.child, L["Attach To"], attachValues, db, "permanentMoverAttachTo", function()
                DF:UpdatePermanentMoverAnchor(GUI.SelectedMode)
            end), 55)
        permAttach.disableOn = function(d) return not d.permanentMover end
        permAttach.tooltip = L["Attach the handle to the container, the first visible unit, or the last visible unit."]

        local function PermMoverAnchorUpdate() DF:UpdatePermanentMoverAnchor(GUI.SelectedMode) end
        local function PermMoverSizeUpdate() DF:UpdatePermanentMoverSize(GUI.SelectedMode) end

        local permOffsetX = permMoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -500, 500, 1, db, "permanentMoverOffsetX", PermMoverAnchorUpdate, PermMoverAnchorUpdate), 55)
        permOffsetX.disableOn = function(d) return not d.permanentMover end

        local permOffsetY = permMoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -500, 500, 1, db, "permanentMoverOffsetY", PermMoverAnchorUpdate, PermMoverAnchorUpdate), 55)
        permOffsetY.disableOn = function(d) return not d.permanentMover end

        local permWidth = permMoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Handle Width"], 5, 500, 1, db, "permanentMoverWidth", PermMoverSizeUpdate, PermMoverSizeUpdate), 55)
        permWidth.disableOn = function(d) return not d.permanentMover end

        local permHeight = permMoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Handle Height"], 5, 500, 1, db, "permanentMoverHeight", PermMoverSizeUpdate, PermMoverSizeUpdate), 55)
        permHeight.disableOn = function(d) return not d.permanentMover end

        local permHover = permMoverGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show on Hover Only"], db, "permanentMoverShowOnHover", function()
            DF:UpdatePermanentMoverVisibility()
        end), 30)
        permHover.disableOn = function(d) return not d.permanentMover end
        permHover.tooltip = L["Handle is invisible until you hover over it. Fades in and out smoothly."]

        local permCombat = permMoverGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "permanentMoverHideInCombat", function()
            DF:UpdatePermanentMoverCombatState()
        end), 30)
        permCombat.disableOn = function(d) return not d.permanentMover end
        permCombat.tooltip = L["Hides the handle during combat. If disabled, the handle changes color to indicate it is locked."]

        local permColor = permMoverGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Handle Color"], db, "permanentMoverColor", false, function()
            DF:UpdatePermanentMoverColor(GUI.SelectedMode)
        end), 35)
        permColor.disableOn = function(d) return not d.permanentMover end

        local permCombatColor = permMoverGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Combat Color"], db, "permanentMoverCombatColor", false, nil), 35)
        permCombatColor.disableOn = function(d) return not d.permanentMover end
        permCombatColor.tooltip = L["Color shown when in combat to indicate the handle is locked."]

        -- Quick action dropdowns
        local actionValues = {}
        for id, data in pairs(DF.PERM_MOVER_ACTIONS) do
            actionValues[id] = data.label
        end

        local permActionLeft = permMoverGroup:AddWidget(GUI:CreateDropdown(self.child, L["Left Click"], actionValues, db, "permanentMoverActionLeft"), 55)
        permActionLeft.disableOn = function(d) return not d.permanentMover end

        local permActionRight = permMoverGroup:AddWidget(GUI:CreateDropdown(self.child, L["Right Click"], actionValues, db, "permanentMoverActionRight"), 55)
        permActionRight.disableOn = function(d) return not d.permanentMover end

        local permActionShiftLeft = permMoverGroup:AddWidget(GUI:CreateDropdown(self.child, L["Shift+Left Click"], actionValues, db, "permanentMoverActionShiftLeft"), 55)
        permActionShiftLeft.disableOn = function(d) return not d.permanentMover end

        local permActionShiftRight = permMoverGroup:AddWidget(GUI:CreateDropdown(self.child, L["Shift+Right Click"], actionValues, db, "permanentMoverActionShiftRight"), 55)
        permActionShiftRight.disableOn = function(d) return not d.permanentMover end

        local permPullTimer = permMoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Pull Timer Duration"], 3, 30, 1, db, "permanentMoverPullTimerDuration"), 55)
        permPullTimer.disableOn = function(d) return not d.permanentMover end
        permPullTimer.tooltip = L["Duration in seconds for the Pull Timer quick action."]

        Add(permMoverGroup, nil, 2)

        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_sorting", label = L["Sorting"]},
            {pageId = "bars_health", label = L["Health Bar"]},
            -- LEGACY-TEXT-CLEANUP: legacy text page hidden; link removed
            -- {pageId = "text_name", label = L["Name Text"]},
        }), 30, "both")
    end)
    
    -- General > Global Fonts
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
            db.targetedSpellDurationFont = font; db.targetedSpellDurationOutline = outline
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
            if DF.UpdateAllTargetedSpellLayouts then DF:UpdateAllTargetedSpellLayouts() end
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

            print("|cff00ff00DandersFrames:|r Applied global font settings to all text elements.")
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
        Add(formatGroup, nil, 1)
        
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
        Add(fontGroup, nil, 1)
        
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
        Add(positionGroup, nil, 2)
        
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

        if not StaticPopupDialogs["DANDERS_PINNED_REMOVE_SET"] then
            StaticPopupDialogs["DANDERS_PINNED_REMOVE_SET"] = {
                text = L["Remove this pinned set? Its members and settings will be lost."],
                button1 = YES, button2 = NO,
                timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true,
                OnAccept = function(_, data)
                    if data and DF.PinnedFrames and DF.PinnedFrames:RemoveSet(data.idx, data.mode) then
                        if pagePinnedFrames.persistedTab > 1 then
                            pagePinnedFrames.persistedTab = pagePinnedFrames.persistedTab - 1
                        end
                        if data.rebuild then data.rebuild() end
                    end
                end,
            }
        end

        local function DoRemoveSet(idx)
            if not DF.PinnedFrames then return end
            -- Capture the edited mode at click time (robust if the GUI mode changes
            -- while the confirm popup is open). Party/raid set lists are independent.
            StaticPopup_Show("DANDERS_PINNED_REMOVE_SET", nil, nil, { idx = idx, mode = GUI.SelectedMode, rebuild = RebuildPinnedPage })
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

        AddSpace(10, "both")

        -- Helper to get the pinned override key for the current active tab
        local function GetPinnedKey(dbKey)
            return "pinned." .. activeHighlightTab .. "." .. dbKey
        end
        
        -- Add override indicators (star, reset, global text) to a pinned frame control
        local function AddPinnedOverrideIndicators(container, lbl, dbKey, onReset)
            local AutoProfilesUI = DF.AutoProfilesUI
            if not AutoProfilesUI then return end
            
            -- Reset button
            local resetBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
            resetBtn:SetSize(18, 18)
            resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
            resetBtn:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            resetBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            resetBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            resetBtn:Hide()
            
            local resetIcon = resetBtn:CreateTexture(nil, "OVERLAY")
            resetIcon:SetPoint("CENTER")
            resetIcon:SetSize(12, 12)
            resetIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
            resetIcon:SetVertexColor(0.6, 0.6, 0.6)
            
            resetBtn:SetScript("OnEnter", function(s)
                s:SetBackdropBorderColor(1, 0.8, 0.2, 1)
                resetIcon:SetVertexColor(1, 0.8, 0.2)
                GUI:ShowTooltip(s, { title = L["Reset to Global"] })
            end)
            resetBtn:SetScript("OnLeave", function(s)
                s:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                resetIcon:SetVertexColor(0.6, 0.6, 0.6)
                GameTooltip:Hide()
            end)
            resetBtn:SetScript("OnClick", function()
                if onReset then onReset() end
            end)
            container.overrideResetBtn = resetBtn
            
            -- Star icon (Button with invisible backdrop for reliable mouse events)
            local starFrame = CreateFrame("Button", nil, container, "BackdropTemplate")
            starFrame:SetSize(18, 18)
            starFrame:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
            starFrame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            starFrame:SetBackdropColor(0, 0, 0, 0)
            starFrame:SetBackdropBorderColor(0, 0, 0, 0)
            starFrame:Hide()
            local starIcon = starFrame:CreateTexture(nil, "OVERLAY")
            starIcon:SetSize(12, 12)
            starIcon:SetPoint("CENTER")
            starIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
            starIcon:SetVertexColor(1, 0.8, 0.2)
            starFrame:SetScript("OnEnter", function(s)
                if s.tooltipText then
                    GUI:ShowTooltip(s, {
                        title = s.tooltipText,
                        lines = s.tooltipSubText and { s.tooltipSubText } or nil,
                    })
                end
            end)
            starFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
                    self.overrideStar.tooltipText = L["Overridden by Auto Layout"]
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
                    self.overrideStar.tooltipText = L["Overridden in this layout"]
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
                cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
            local resetBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
            resetBtn:SetSize(18, 18)
            resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
            resetBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            resetBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            resetBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            resetBtn:Hide()
            local resetIcon = resetBtn:CreateTexture(nil, "OVERLAY")
            resetIcon:SetPoint("CENTER")
            resetIcon:SetSize(12, 12)
            resetIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
            resetIcon:SetVertexColor(0.6, 0.6, 0.6)
            resetBtn:SetScript("OnEnter", function(s)
                s:SetBackdropBorderColor(1, 0.8, 0.2, 1); resetIcon:SetVertexColor(1, 0.8, 0.2)
                GUI:ShowTooltip(s, { title = L["Reset to inherited value"] })
            end)
            resetBtn:SetScript("OnLeave", function(s)
                s:SetBackdropBorderColor(0.3, 0.3, 0.3, 1); resetIcon:SetVertexColor(0.6, 0.6, 0.6); GameTooltip:Hide()
            end)

            local starFrame = CreateFrame("Button", nil, container, "BackdropTemplate")
            starFrame:SetSize(18, 18)
            starFrame:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
            starFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            starFrame:SetBackdropColor(0, 0, 0, 0)
            starFrame:SetBackdropBorderColor(0, 0, 0, 0)
            starFrame:Hide()
            local starIcon = starFrame:CreateTexture(nil, "OVERLAY")
            starIcon:SetSize(12, 12)
            starIcon:SetPoint("CENTER")
            starIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
            starIcon:SetVertexColor(1, 0.8, 0.2)
            starFrame:SetScript("OnEnter", function(s)
                GUI:ShowTooltip(s, {
                    title = L["Overriding inherited value"],
                    lines = {
                        string.format(L["Inherited value: %s"], FmtVal(MatchValue())),
                    },
                })
            end)
            starFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
        local showLabelCheck = settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Show Label"], "showLabel", function()
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
        local hideAurasCheck = settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Hide Auras"], "hideAuras", RefreshPinnedDisplay), 28)
        local hideIconsCheck = settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Hide Status Icons"], "hideIcons", RefreshPinnedDisplay), 28)

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
        dpvpCB:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
        layoutGroup:AddWidget(CreatePinnedPresetDropdown(self.child, L["Aura Designer Preset"], "aura", "auraDesignerPreset", RefreshPinnedDisplay), 55)
        if DF.TextDesigner then
            layoutGroup:AddWidget(CreatePinnedPresetDropdown(self.child, L["Text Designer Preset"], "text", "textDesignerPreset", RefreshPinnedDisplay), 55)
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
            local rb = CreateFrame("Button", nil, borderCheck, "BackdropTemplate")
            rb:SetSize(18, 18)
            rb:SetPoint("TOPRIGHT", borderCheck, "TOPRIGHT", 0, -2)
            rb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            rb:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            rb:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            local ic = rb:CreateTexture(nil, "OVERLAY")
            ic:SetPoint("CENTER"); ic:SetSize(12, 12)
            ic:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
            ic:SetVertexColor(0.6, 0.6, 0.6)
            rb:SetScript("OnEnter", function(s)
                s:SetBackdropBorderColor(1, 0.8, 0.2, 1); ic:SetVertexColor(1, 0.8, 0.2)
                GUI:ShowTooltip(s, { title = L["Reset Border to Inherited"] })
            end)
            rb:SetScript("OnLeave", function(s)
                s:SetBackdropBorderColor(0.3, 0.3, 0.3, 1); ic:SetVertexColor(0.6, 0.6, 0.6); GameTooltip:Hide()
            end)
            rb:SetScript("OnClick", function()
                if DF.PinnedFrames then DF.PinnedFrames:SeedSetBorderOverride(GetCurrentSet(), true) end
                UpdateHighlightLayout()
                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            end)
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
        local autoPopGroup = GUI:CreateSettingsGroup(self.child, 280)
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

    pagePinnedFrames:SetScript("OnHide", function()
        if DF.PinnedFrames then
            DF.PinnedFrames:HidePreview()
        end
    end)

    -- General > Sorting
    local pageSorting = CreateSubTab("general", "general_sorting", L["Sorting"])
    BuildPage(pageSorting, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"sort", "selfPosition", "rolePriority", "classPriority"}, L["Sorting"], "general_sorting"), 25, 2)
        
        -- Helper function to trigger sort for current mode
        local function TriggerSortForCurrentMode()
            if DF.testMode or DF.raidTestMode then
                if DF.RefreshTestFramesWithLayout then DF:RefreshTestFramesWithLayout() end
                return
            end
            if DF.headersInitialized then DF:ApplyHeaderSettings() end
            -- Arena: ApplyHeaderSettings handles orientation but not sorting.
            -- Call ApplyArenaHeaderSorting directly for settings changes from the GUI.
            if DF.IsInArena and DF:IsInArena() then
                if not InCombatLockdown() and DF.ApplyArenaHeaderSorting then
                    DF:ApplyArenaHeaderSorting()
                end
            elseif GUI.SelectedMode == "raid" then
                if DF.SecureSort then
                    DF.SecureSort:PushRaidSortSettings()
                    DF.SecureSort:TriggerSecureRaidSort()
                end
            else
                if DF.Sort then DF.Sort:TriggerResort() end
            end
        end
        
        -- When FrameSort takes over ordering, DF's own sort options are
        -- irrelevant and HIDE (variant gate). Otherwise they GREY OUT
        -- (disabled-in-place) while custom sorting is off rather than vanishing.
        local function HideSortOptions(d)
            return d.useFrameSort and FrameSortApi
        end
        local function DisableSortOptions(d)
            return not d.sortEnabled
        end
        
        -- Store reference to role widget so we can refresh it
        local roleOrderWidget = nil
        
        -- ===== COMBAT STATUS BANNER (full width) =====
        local combatBanner = GUI:CreateInfoBanner(self.child, { fontTemplate = "DFFontNormal" })

        local function UpdateCombatBanner()
            if not db.sortEnabled then
                combatBanner:Hide()
                return
            end
            combatBanner:Show()

            local selfPos = db.sortSelfPosition or "SORTED"
            local hasAdvancedOptions = db.sortSeparateMeleeRanged or db.sortByClass or db.sortAlphabetical

            if hasAdvancedOptions then
                combatBanner:SetTone("danger")
                combatBanner:SetText(L["Combat Limitation: All groups will not update with new players that join mid-combat."])
            elseif selfPos == "FIRST" or selfPos == "LAST" then
                combatBanner:SetTone("caution")
                -- Override default warning icon with info icon for this softer state.
                combatBanner:SetIconTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\info")
                combatBanner:SetText(L["Combat Limitation: Your group will not update with new players that join mid-combat."])
            else
                combatBanner:SetTone("success")
                combatBanner:SetText(L["Fully Combat Safe: Frames will update normally during combat."])
            end
        end

        -- Hide when an external FrameSort addon owns sorting OR our sorting is off
        -- (the combat banner is only meaningful while our sorting is enabled).
        -- Without the sortEnabled check, the page's RefreshStates re-showed the
        -- banner after UpdateCombatBanner had hidden it -- a white, tone-less box.
        combatBanner.hideOn = function(d) return HideSortOptions(d) or not d.sortEnabled end
        -- Reapply tone + text on every page refresh. RefreshStates calls
        -- refreshContent (not the old custom UpdateBanner method), so the banner
        -- never shows without a tone (the backdrop defaults to white until toned).
        combatBanner.refreshContent = UpdateCombatBanner
        Add(combatBanner, combatBanner.layoutHeight, "both")

        -- Initial update
        UpdateCombatBanner()
        
        -- ===== SORTING OPTIONS GROUP (Column 1) =====
        local sortOptionsGroup = GUI:CreateSettingsGroup(self.child, 280)
        sortOptionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Unit Frame Sorting"]), 40)
        sortOptionsGroup:AddWidget(GUI:CreateLabel(self.child, L["Sort party members by role, class, and name.\n\nSort order: Self Position > Role > Class > Name"], 250), 60)
        
        local raidSortNote = sortOptionsGroup:AddWidget(GUI:CreateLabel(self.child, L["Raid: Group layout sorts within each group.\nFlat grid layout sorts all players together."], 250), 35)
        raidSortNote.hideOn = function() return GUI.SelectedMode ~= "raid" end

        local sortEnable = sortOptionsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Custom Sorting"], db, "sortEnabled", function()
            TriggerSortForCurrentMode()
            UpdateCombatBanner()
            self:RefreshStates()
        end), 30)
        sortEnable.keepEnabled = true
        sortOptionsGroup.disableChildrenOn = DisableSortOptions

        local sortMeleeRanged = sortOptionsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Separate Melee & Ranged DPS"], db, "sortSeparateMeleeRanged", function()
            TriggerSortForCurrentMode()
            if roleOrderWidget and roleOrderWidget.Refresh then roleOrderWidget.Refresh() end
            UpdateCombatBanner()
        end), 30)
        sortMeleeRanged.hideOn = HideSortOptions
        
        local sortByClass = sortOptionsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Sort by Class (within role)"], db, "sortByClass", function()
            TriggerSortForCurrentMode()
            self:RefreshStates()
            UpdateCombatBanner()
        end), 30)
        sortByClass.hideOn = HideSortOptions
        
        local sortAlphaValues = {
            [false] = L["Off"],
            ["AZ"] = L["A to Z"],
            ["ZA"] = L["Z to A"],
            _order = {false, "AZ", "ZA"},
        }
        local sortAlpha = sortOptionsGroup:AddWidget(GUI:CreateDropdown(self.child, L["Alphabetical (within class/role)"], sortAlphaValues, db, "sortAlphabetical", function()
            TriggerSortForCurrentMode()
            UpdateCombatBanner()
        end), 55)
        sortAlpha.hideOn = HideSortOptions
        
        Add(sortOptionsGroup, nil, 1)

        -- ===== FRAMESORT INTEGRATION GROUP (Column 1) =====
        if FrameSortApi then
            local frameSortGroup = GUI:CreateSettingsGroup(self.child, 280)
            frameSortGroup:AddWidget(GUI:CreateHeader(self.child, L["FrameSort Integration"]), 40)
            frameSortGroup:AddWidget(GUI:CreateLabel(self.child, format(L["FrameSort addon detected. Enable to let FrameSort control frame ordering.\n\n%sExperimental:%s This feature is new and may not work perfectly in all scenarios. Please report any issues."], "|c" .. GUI:ToneHex("caution"), "|r"), 250), 70)
            frameSortGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use FrameSort Addon"], db, "useFrameSort", function()
                -- Set both modes simultaneously
                local partyDB = DF:GetDB("party")
                local raidDB = DF:GetDB("raid")
                if partyDB then partyDB.useFrameSort = db.useFrameSort end
                if raidDB then raidDB.useFrameSort = db.useFrameSort end
                -- Notify the FrameSort module
                if DF.FrameSort and DF.FrameSort.OnSettingChanged then
                    DF.FrameSort:OnSettingChanged()
                end
                -- Trigger a re-sort so the change takes effect immediately
                TriggerSortForCurrentMode()
                -- Refresh options visibility
                self:RefreshStates()
            end), 30)
            Add(frameSortGroup, nil, 1)
        end

        -- ===== SELF POSITION GROUP (Column 1) =====
        local selfPosGroup = GUI:CreateSettingsGroup(self.child, 280)
        selfPosGroup:AddWidget(GUI:CreateHeader(self.child, L["Self Position"]), 40)
        
        local selfPosValues = {
            ["FIRST"] = L["Always First"],
            ["LAST"] = L["Always Last"],
            ["SORTED"] = L["Sorted with Group"],
            ["NORMAL"] = L["Sorted with Group"],
            _order = {"FIRST", "LAST", "SORTED"},
        }
        selfPosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Position"], selfPosValues, db, "sortSelfPosition", function()
            TriggerSortForCurrentMode()
            UpdateCombatBanner()
        end), 55)
        selfPosGroup.hideOn = HideSortOptions
        selfPosGroup.disableChildrenOn = DisableSortOptions
        Add(selfPosGroup, nil, 1)
        
        -- ===== ROLE PRIORITY GROUP (Column 2) =====
        local rolePriorityGroup = GUI:CreateSettingsGroup(self.child, 280)
        rolePriorityGroup:AddWidget(GUI:CreateHeader(self.child, L["Role Priority"]), 40)
        rolePriorityGroup:AddWidget(GUI:CreateLabel(self.child, L["Drag to reorder. Top = first."], 250), 25)
        
        roleOrderWidget = GUI:CreateRoleOrderList(self.child, db, "sortRoleOrder", function()
            TriggerSortForCurrentMode()
        end, "sortSeparateMeleeRanged")
        rolePriorityGroup:AddWidget(roleOrderWidget, 135)
        rolePriorityGroup.hideOn = HideSortOptions
        rolePriorityGroup.disableChildrenOn = DisableSortOptions
        Add(rolePriorityGroup, nil, 2)
        
        -- ===== CLASS PRIORITY GROUP (Column 2) =====
        local classPriorityGroup = GUI:CreateSettingsGroup(self.child, 280)
        classPriorityGroup:AddWidget(GUI:CreateHeader(self.child, L["Class Priority"]), 40)
        classPriorityGroup:AddWidget(GUI:CreateLabel(self.child, L["Drag to reorder. Top = first."], 250), 25)
        
        local classOrderWidget = GUI:CreateClassOrderList(self.child, db, "sortClassOrder", function()
            TriggerSortForCurrentMode()
        end)
        classPriorityGroup:AddWidget(classOrderWidget, 320)
        -- Hide under FrameSort takeover or when not sorting by class (variant
        -- gates); grey out when custom sorting is disabled (enable gate).
        classPriorityGroup.hideOn = function(d) return (d.useFrameSort and FrameSortApi) or not d.sortByClass end
        classPriorityGroup.disableChildrenOn = DisableSortOptions
        Add(classPriorityGroup, nil, 2)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_frame", label = L["Frame"]},
            {pageId = "general_labels", label = L["Group Labels"]},
        }), 30, "both")
    end)
    
    -- General > Nicknames (account-wide list; custom builder, no party/raid switch)
    local pageNicknames = CreateSubTab("general", "general_nicknames", L["Nicknames"])
    BuildPage(pageNicknames, function(self, db, Add, AddSpace, AddSyncPoint)
        if DF.BuildNicknamesPage then
            DF.BuildNicknamesPage(GUI, self, db, Add, AddSpace)
        end
    end)

    -- General > Integrations
    local pageIntegrations = CreateSubTab("general", "general_integrations", L["Integrations"])
    BuildPage(pageIntegrations, function(self, db, Add, AddSpace, AddSyncPoint)
        Add(CreateCopyButton(self.child, {"colorPicker", "masque", "buffDisableMouse", "debuffDisableMouse", "defensiveIconDisableMouse", "targetedSpellDisableMouse"}, L["Integrations"], "general_integrations"), 25, 2)
        -- ===== COLOR PICKER GROUP (Column 1) =====
        local colorPickerGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorPickerGroup:AddWidget(GUI:CreateHeader(self.child, L["Color Picker"]), 40)
        
        colorPickerGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use DF Color Picker"], db, "colorPickerOverride", function()
            if db.colorPickerOverride or db.colorPickerGlobalOverride then
                GUI:InstallColorPickerHook()
            else
                GUI:UninstallColorPickerHook()
            end
            if db.colorPickerOverride then
                print("|cff00ff00DandersFrames:|r Color picker override enabled")
            else
                print("|cffff9900DandersFrames:|r Color picker override disabled")
            end
        end), 30)
        colorPickerGroup:AddWidget(GUI:CreateLabel(self.child, L["Replace Blizzard's color picker with the DandersFrames color picker for this addon."], 250), 40)
        
        colorPickerGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use DF Color Picker for All Addons"], db, "colorPickerGlobalOverride", function()
            if db.colorPickerOverride or db.colorPickerGlobalOverride then
                GUI:InstallColorPickerHook()
            else
                GUI:UninstallColorPickerHook()
            end
            if db.colorPickerGlobalOverride then
                print("|cff00ff00DandersFrames:|r Custom color picker enabled for all addons")
            else
                print("|cffff9900DandersFrames:|r Custom color picker disabled for all addons")
            end
        end), 30)
        colorPickerGroup:AddWidget(GUI:CreateLabel(self.child, L["Show the DF color picker when any addon opens a color picker."], 250), 30)
        
        Add(colorPickerGroup, nil, 1)
        
        -- ===== MASQUE GROUP (Column 2) =====
        local masqueGroup = GUI:CreateSettingsGroup(self.child, 280)
        masqueGroup:AddWidget(GUI:CreateHeader(self.child, L["Masque Integration"]), 40)
        
        if DF.Masque then
            local masqueBorderChk = masqueGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Let Masque Control Aura Borders"], db, "masqueBorderControl", function()
                if DF.ApplyLayout then DF:ApplyLayout() end
                if DF.UpdateAllFrames then DF:UpdateAllFrames() end
                print("|cff00ff00DandersFrames:|r Masque border control " .. (db.masqueBorderControl and L["enabled"] or L["disabled"]) .. ". A /reload may be needed.")
            end), 30)
            GUI:BlockControl12_1(masqueBorderChk, "roadmap", { id = "integrations:masqueborder", page = L["Integrations"] })
            masqueGroup:AddWidget(GUI:CreateLabel(self.child, L["When enabled, Masque skins aura icons and borders. DF border settings will be disabled."], 250), 45)
        else
            masqueGroup:AddWidget(GUI:CreateLabel(self.child, L["Masque addon is not installed.\n\nMasque allows you to skin buff/debuff icons with custom textures. Install Masque from CurseForge to enable."], 250), 75)
        end
        
        Add(masqueGroup, nil, 2)
        
        -- ===== CLICK-THROUGH GROUP (Column 1) =====
        local clickThroughGroup = GUI:CreateSettingsGroup(self.child, 280)
        clickThroughGroup:AddWidget(GUI:CreateHeader(self.child, L["Click-Through Icons"]), 40)
        clickThroughGroup:AddWidget(GUI:CreateLabel(self.child, L["Make icons click-through for external click-casting addons. Not needed for DF built-in click-casting."], 250), 45)
        
        local buffDisableMouse = clickThroughGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Buff Icons Click-Through"], db, "buffDisableMouse", function()
            if DF.UpdateAuraClickThrough then DF:UpdateAuraClickThrough() end
        end), 30)
        buffDisableMouse.disableOn = function(d) return not d.showBuffs end
        
        local debuffDisableMouse = clickThroughGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Debuff Icons Click-Through"], db, "debuffDisableMouse", function()
            if DF.UpdateAuraClickThrough then DF:UpdateAuraClickThrough() end
        end), 30)
        debuffDisableMouse.disableOn = function(d) return not d.showDebuffs end
        GUI:BlockControl12_1(debuffDisableMouse, "roadmap", { id = "integrations:debuffclickthrough", page = L["Integrations"],
            when = function(d) return GUI:IsAuraFactoryActive() and not DF:FactoryOwnsDebuffRow(d) end })
        
        local defensiveDisableMouse = clickThroughGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Defensive Icon Click-Through"], db, "defensiveIconDisableMouse", function()
            if DF.UpdateAuraClickThrough then DF:UpdateAuraClickThrough() end
        end), 30)
        defensiveDisableMouse.disableOn = function(d) return not d.defensiveIconEnabled end
        GUI:BlockControl12_1(defensiveDisableMouse, "roadmap", { id = "integrations:defensiveclickthrough", page = L["Integrations"],
            when = function(d) return GUI:IsAuraFactoryActive() and not DF:FactoryOwnsDefensiveRow(d) end })
        
        local tsDisableMouse = clickThroughGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Targeted Spell Click-Through"], db, "targetedSpellDisableMouse", function()
            if DF.UpdateAuraClickThrough then DF:UpdateAuraClickThrough() end
        end), 30)
        tsDisableMouse.disableOn = function(d) return not d.targetedSpellEnabled end
        
        clickThroughGroup:AddWidget(GUI:CreateNote(self.child, L["Click-through icons will not show tooltips."], {tone = "caution", prefix = "Note", width = 250}), 25)
        
        Add(clickThroughGroup, nil, 1)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buffs"]},
            {pageId = "auras_debuffs", label = L["Debuffs"]},
            {pageId = "auras_defensiveicon", label = L["Defensive Icon"]},
            {pageId = "indicators_targetedspells", label = L["Targeted Spells"]},
        }), 30, "both")
    end)
    
    -- Display > Colors  (was "Class Colors" pre-Stage 2; renamed when role
    -- colours moved here so the page houses BOTH the class set and the role
    -- set used by every border that opts into include.classColor /
    -- include.roleColor in CreateBorderControls.)
    local pageColors = CreateSubTab("display", "display_classcolors", L["Colors"])
    BuildPage(pageColors, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Class colors are shared across party/raid, stored at profile level
        local classColorsDB = DF.db.classColors
        if not classColorsDB then
            DF.db.classColors = {}
            classColorsDB = DF.db.classColors
        end

        -- Role colors live at profile level too (DF.db.roleColors), seeded by
        -- DF:MigrateRoleBorderColors on db load.
        local roleColorsDB = DF.db.roleColors
        if not roleColorsDB then
            DF.db.roleColors = {}
            roleColorsDB = DF.db.roleColors
        end

        -- Ordered list of all classes with display names
        local CLASS_LIST = {
            { token = "WARRIOR",      name = L["Warrior"] },
            { token = "PALADIN",      name = L["Paladin"] },
            { token = "HUNTER",       name = L["Hunter"] },
            { token = "ROGUE",        name = L["Rogue"] },
            { token = "PRIEST",       name = L["Priest"] },
            { token = "DEATHKNIGHT",  name = L["Death Knight"] },
            { token = "SHAMAN",       name = L["Shaman"] },
            { token = "MAGE",         name = L["Mage"] },
            { token = "WARLOCK",      name = L["Warlock"] },
            { token = "MONK",         name = L["Monk"] },
            { token = "DRUID",        name = L["Druid"] },
            { token = "DEMONHUNTER",  name = L["Demon Hunter"] },
            { token = "EVOKER",       name = L["Evoker"] },
        }

        local ROLE_LIST = {
            { token = "TANK",    name = L["Tank"]    },
            { token = "HEALER",  name = L["Healer"]  },
            { token = "DAMAGER", name = L["Damager"] },
        }
        local ROLE_DEFAULTS = {
            TANK    = {r = 0.20, g = 0.55, b = 0.95, a = 1},
            HEALER  = {r = 0.20, g = 0.80, b = 0.30, a = 1},
            DAMAGER = {r = 0.85, g = 0.20, b = 0.20, a = 1},
        }

        -- ===== Column 1 =====
        local col1 = GUI:CreateSettingsGroup(self.child, 280)
        col1:AddWidget(GUI:CreateHeader(self.child, L["Class Colors"]), 40)
        col1:AddWidget(GUI:CreateLabel(self.child, L["Customize class colors used throughout DandersFrames. Changes apply to health bars, name text, borders, and all other class-colored elements."], 260), 50)
        
        -- Reset All button
        local resetAllBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        GUI:StyleButton(resetAllBtn, { width = 260, height = 24, text = L["Reset All to Default"] })
        resetAllBtn:SetScript("OnClick", function()
            -- Reset all to Blizzard defaults
            for _, info in ipairs(CLASS_LIST) do
                local default = RAID_CLASS_COLORS[info.token]
                if default then
                    classColorsDB[info.token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            DF:RefreshAllVisibleFrames()
            -- Refresh the options page to update swatches
            if pageColors and pageColors.Refresh then
                pageColors:Refresh()
            end
        end)
        col1:AddWidget(resetAllBtn, 30)
        
        -- All classes in a single section
        for i = 1, #CLASS_LIST do
            local info = CLASS_LIST[i]
            local token = info.token
            -- Initialize from Blizzard defaults if not customized
            if not classColorsDB[token] then
                local default = RAID_CLASS_COLORS[token]
                if default then
                    classColorsDB[token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            col1:AddWidget(GUI:CreateColorPicker(self.child, info.name, classColorsDB, token, false, function()
                DF:RefreshAllVisibleFrames()
            end, function()
                DF:RefreshAllVisibleFrames()
            end, true), 30)
        end

        Add(col1, nil, 1)

        -- ===== Column 2: Role Colors =====
        local col2 = GUI:CreateSettingsGroup(self.child, 280)
        col2:AddWidget(GUI:CreateHeader(self.child, L["Role Colors"]), 40)
        col2:AddWidget(GUI:CreateLabel(self.child, L["Customize role colors used by any border whose Color Source is set to Role. Applies to Tank, Healer, and Damager assignments."], 260), 50)

        local roleResetBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        GUI:StyleButton(roleResetBtn, { width = 260, height = 24, text = L["Reset All to Default"] })
        roleResetBtn:SetScript("OnClick", function()
            for _, info in ipairs(ROLE_LIST) do
                local d = ROLE_DEFAULTS[info.token]
                if d then roleColorsDB[info.token] = { r = d.r, g = d.g, b = d.b, a = d.a } end
            end
            DF:RefreshAllVisibleFrames()
            if pageColors and pageColors.Refresh then pageColors:Refresh() end
        end)
        col2:AddWidget(roleResetBtn, 30)

        for i = 1, #ROLE_LIST do
            local info = ROLE_LIST[i]
            if not roleColorsDB[info.token] then
                local d = ROLE_DEFAULTS[info.token]
                if d then roleColorsDB[info.token] = { r = d.r, g = d.g, b = d.b, a = d.a } end
            end
            col2:AddWidget(GUI:CreateColorPicker(self.child, info.name, roleColorsDB, info.token, false, function()
                DF:RefreshAllVisibleFrames()
            end, function()
                DF:RefreshAllVisibleFrames()
            end, true), 30)
        end

        Add(col2, nil, 2)
    end)
    
    -- ========================================
    -- CATEGORY: Bars
    -- ========================================
    CreateCategory("bars", L["Bars"])
    
    -- Bars > Health Bar
    local pageHealthBar = CreateSubTab("bars", "bars_health", L["Health Bar"])
    BuildPage(pageHealthBar, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"healthColor", "healthOrientation", "healthTexture", "classColor", "smoothBars", "background", "missingHealth", "reducedMaxHealth"}, L["Health Bar"], "bars_health"), 25, 2)
        
        local currentSection = nil
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        -- ===== HEALTH BAR SECTION =====
        local healthBarSection = Add(GUI:CreateCollapsibleSection(self.child, L["Health Bar"], true), 36, "both")
        currentSection = healthBarSection
        
        -- ===== COLOR GROUP (Column 1) =====
        local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorGroup:AddWidget(GUI:CreateHeader(self.child, L["Color"]), 40)
        
        local colorModes = { CLASS= L["Class Color"], CUSTOM= L["Custom Color"], PERCENT= L["Health Gradient"] }
        colorGroup:AddWidget(GUI:CreateDropdown(self.child, L["Color Mode"], colorModes, db, "healthColorMode", function()
            self:RefreshStates()
            DF:UpdateColorCurve()
            -- Refresh health colors on all frames (same as alpha slider)
            DF:RefreshAllVisibleFrames()
        end), 55)
        
        local classAlpha = colorGroup:AddWidget(GUI:CreateSlider(self.child, L["Health Bar Alpha"], 0, 1, 0.05, db, "classColorAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        classAlpha.hideOn = function(d) return d.healthColorMode ~= "CLASS" and d.healthColorMode ~= "PERCENT" end
        
        local customColor = colorGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Custom Health Color"], db, "healthColor", true, nil, function() DF:LightweightUpdateHealthColor() end, true), 35)
        customColor.hideOn = function(d) return d.healthColorMode ~= "CUSTOM" end
        
        AddToSection(colorGroup, nil, 1)
        
        -- ===== TEXTURE GROUP (Column 2) =====
        local textureGroup = GUI:CreateSettingsGroup(self.child, 280)
        textureGroup:AddWidget(GUI:CreateHeader(self.child, L["Texture"]), 40)
        textureGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "healthTexture"), 55)
        
        local orientOptions = {
            HORIZONTAL= L["Left to Right"], HORIZONTAL_INV= L["Right to Left"],
            VERTICAL= L["Bottom to Top"], VERTICAL_INV= L["Top to Bottom"],
        }
        textureGroup:AddWidget(GUI:CreateDropdown(self.child, L["Fill Direction"], orientOptions, db, "healthOrientation", function() DF:UpdateAllFrames() end), 55)
        textureGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Smooth Bar Animation"], db, "smoothBars", function() DF:UpdateAllFrames() end), 30)
        
        AddToSection(textureGroup, nil, 2)
        
        -- ===== GRADIENT PREVIEW (full width, conditional) =====
        local gradHeader = AddToSection(GUI:CreateHeader(self.child, L["Gradient"]), 40, "both")
        gradHeader.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        
        local gradBar = AddToSection(GUI:CreateGradientBar(self.child, 550, 24, db), 35, "both")
        gradBar.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        
        -- ===== HIGH HEALTH GROUP (Column 1, conditional) =====
        local highGroup = GUI:CreateSettingsGroup(self.child, 280)
        highGroup:AddWidget(GUI:CreateHeader(self.child, L["High Health (100%)"]), 40)
        highGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "healthColorHigh", false, function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 35)
        highGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "healthColorHighUseClass", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        highGroup:AddWidget(GUI:CreateSlider(self.child, L["Weight"], 1, 5, 1, db, "healthColorHighWeight", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 55)
        highGroup.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        AddToSection(highGroup, nil, 1)
        
        -- ===== MEDIUM HEALTH GROUP (Column 2, conditional) =====
        local medGroup = GUI:CreateSettingsGroup(self.child, 280)
        medGroup:AddWidget(GUI:CreateHeader(self.child, L["Medium Health (50%)"]), 40)
        medGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "healthColorMedium", false, function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 35)
        medGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "healthColorMediumUseClass", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        medGroup:AddWidget(GUI:CreateSlider(self.child, L["Weight"], 1, 5, 1, db, "healthColorMediumWeight", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 55)
        medGroup.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        AddToSection(medGroup, nil, 2)
        
        -- ===== LOW HEALTH GROUP (Column 1, conditional) =====
        local lowGroup = GUI:CreateSettingsGroup(self.child, 280)
        lowGroup:AddWidget(GUI:CreateHeader(self.child, L["Low Health (0%)"]), 40)
        lowGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "healthColorLow", false, function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 35)
        lowGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "healthColorLowUseClass", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        lowGroup:AddWidget(GUI:CreateSlider(self.child, L["Weight"], 1, 5, 1, db, "healthColorLowWeight", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 55)
        lowGroup.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        AddToSection(lowGroup, nil, 1)
        
        -- ===== BACKGROUND GROUP (Column 1) =====
        local bgGroup = GUI:CreateSettingsGroup(self.child, 280)
        bgGroup:AddWidget(GUI:CreateHeader(self.child, L["Background"]), 40)
        
        local bgModes = { CUSTOM= L["Custom Color"], CLASS= L["Class Color"] }
        bgGroup:AddWidget(GUI:CreateDropdown(self.child, L["Background Mode"], bgModes, db, "backgroundColorMode", function()
            self:RefreshStates()
            DF:LightweightUpdateBackgroundColor()
        end), 55)
        
        local bgTextureOptions = DF:GetTextureList(true)
        bgGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Background Texture"], db, "backgroundTexture", function()
            DF:LightweightUpdateBackgroundColor()
        end, bgTextureOptions), 55)
        
        local bgColor = bgGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "backgroundColor", true, nil, function() DF:LightweightUpdateBackgroundColor() end, true), 35)
        bgColor.hideOn = function(d) return d.backgroundColorMode ~= "CUSTOM" end
        
        local bgClassAlpha = bgGroup:AddWidget(GUI:CreateSlider(self.child, L["Background Alpha"], 0, 1, 0.05, db, "backgroundClassAlpha", nil, function() DF:LightweightUpdateBackgroundColor() end, true), 55)
        bgClassAlpha.hideOn = function(d) return d.backgroundColorMode ~= "CLASS" end
        
        AddToSection(bgGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== MISSING HEALTH SECTION =====
        local missingSection = Add(GUI:CreateCollapsibleSection(self.child, L["Missing Health"], true), 36, "both")
        currentSection = missingSection
        
        -- ===== MISSING HEALTH GROUP (Column 1) =====
        local missingGroup = GUI:CreateSettingsGroup(self.child, 280)
        missingGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        
        local bgFillModes = { BACKGROUND= L["Background Only"], MISSING_HEALTH= L["Missing Health Only"], BOTH= L["Both"] }
        local bgFillMode = missingGroup:AddWidget(GUI:CreateDropdown(self.child, L["Background Fill"], bgFillModes, db, "backgroundMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55)
        bgFillMode.tooltip = L["Background Only: Normal solid background\nMissing Health Only: Shows colored bar where health is missing\nBoth: Shows both"]
        
        local missingHealthTextureOptions = DF:GetTextureList(false)
        local missingHealthTexture = missingGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Missing Health Texture"], db, "missingHealthTexture", function()
            DF:UpdateAllFrames()
        end, missingHealthTextureOptions), 55)
        missingHealthTexture.hideOn = function(d) return d.backgroundMode == "BACKGROUND" end
        
        local missingHealthColorModes = { CUSTOM= L["Custom Color"], CLASS= L["Class Color"], PERCENT= L["Health Gradient"] }
        local missingHealthColorMode = missingGroup:AddWidget(GUI:CreateDropdown(self.child, L["Color Mode"], missingHealthColorModes, db, "missingHealthColorMode", function()
            self:RefreshStates()
            DF:UpdateColorCurve()
            DF:UpdateAllFrames()
        end), 55)
        missingHealthColorMode.hideOn = function(d) return d.backgroundMode == "BACKGROUND" end
        
        local missingHealthColor = missingGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Missing Health Color"], db, "missingHealthColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
        missingHealthColor.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "CUSTOM" end
        
        local missingHealthClassAlpha = missingGroup:AddWidget(GUI:CreateSlider(self.child, L["Class Color Alpha"], 0, 1, 0.05, db, "missingHealthClassAlpha", nil, function() DF:UpdateAllFrames() end, true), 55)
        missingHealthClassAlpha.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "CLASS" end
        
        local missingHealthGradientAlpha = missingGroup:AddWidget(GUI:CreateSlider(self.child, L["Gradient Color Alpha"], 0, 1, 0.05, db, "missingHealthGradientAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        missingHealthGradientAlpha.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT" end

        AddToSection(missingGroup, nil, 1)

        -- ===== MISSING HEALTH GRADIENT PREVIEW (full width, conditional) =====
        local mhGradHeader = AddToSection(GUI:CreateHeader(self.child, L["Gradient"]), 40, "both")
        mhGradHeader.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT" end

        local mhGradBar = AddToSection(GUI:CreateGradientBar(self.child, 550, 24, db, "missingHealthColor"), 35, "both")
        mhGradBar.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT" end

        -- ===== MISSING HEALTH HIGH GROUP (Column 1, conditional) =====
        local mhHighGroup = GUI:CreateSettingsGroup(self.child, 280)
        mhHighGroup:AddWidget(GUI:CreateHeader(self.child, L["High Health (100%)"]), 40)
        mhHighGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "missingHealthColorHigh", false, function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, true), 35)
        mhHighGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "missingHealthColorHighUseClass", function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        mhHighGroup:AddWidget(GUI:CreateSlider(self.child, L["Weight"], 1, 5, 1, db, "missingHealthColorHighWeight", function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, true), 55)
        mhHighGroup.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT" end
        AddToSection(mhHighGroup, nil, 1)

        -- ===== MISSING HEALTH MEDIUM GROUP (Column 2, conditional) =====
        local mhMedGroup = GUI:CreateSettingsGroup(self.child, 280)
        mhMedGroup:AddWidget(GUI:CreateHeader(self.child, L["Medium Health (50%)"]), 40)
        mhMedGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "missingHealthColorMedium", false, function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, true), 35)
        mhMedGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "missingHealthColorMediumUseClass", function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        mhMedGroup:AddWidget(GUI:CreateSlider(self.child, L["Weight"], 1, 5, 1, db, "missingHealthColorMediumWeight", function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, true), 55)
        mhMedGroup.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT" end
        AddToSection(mhMedGroup, nil, 2)

        -- ===== MISSING HEALTH LOW GROUP (Column 1, conditional) =====
        local mhLowGroup = GUI:CreateSettingsGroup(self.child, 280)
        mhLowGroup:AddWidget(GUI:CreateHeader(self.child, L["Low Health (0%)"]), 40)
        mhLowGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "missingHealthColorLow", false, function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, true), 35)
        mhLowGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "missingHealthColorLowUseClass", function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        mhLowGroup:AddWidget(GUI:CreateSlider(self.child, L["Weight"], 1, 5, 1, db, "missingHealthColorLowWeight", function() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if mhGradBar.UpdatePreview then mhGradBar.UpdatePreview() end end, true), 55)
        mhLowGroup.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT" end
        AddToSection(mhLowGroup, nil, 1)

        currentSection = nil

        AddSpace(10, "both")

        -- ===== REDUCED MAX HEALTH SECTION =====
        local reducedSection = Add(GUI:CreateCollapsibleSection(self.child, L["Reduced Max Health"], true), 36, "both")
        currentSection = reducedSection

        -- ===== REDUCED MAX HEALTH SETTINGS GROUP (Column 1) =====
        local reducedGroup = GUI:CreateSettingsGroup(self.child, 280)
        reducedGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        local reducedEnable = reducedGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable"], db, "reducedMaxHealthEnabled", function() self:RefreshStates() DF:UpdateAllFrames() end), 30)
        reducedEnable.keepEnabled = true
        reducedGroup.disableChildrenOn = function(d) return not d.reducedMaxHealthEnabled end
        reducedGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Clip Health Bar"], db, "reducedMaxHealthClipHealthBar", function() DF:UpdateAllFrames() end), 30)
        reducedGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "reducedMaxHealthTexture", function() DF:UpdateAllFrames() end), 55)
        reducedGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Bar Color"], db, "reducedMaxHealthColor", true, nil, function() DF:LightweightUpdateReducedMaxHealthColor() end, true), 35)
        local reducedBlendOpts = { BLEND = L["Blend"], ADD = L["Add"], MOD = L["Modulate"] }
        reducedGroup:AddWidget(GUI:CreateDropdown(self.child, L["Blend Mode"], reducedBlendOpts, db, "reducedMaxHealthBlendMode", function() DF:UpdateAllFrames() end), 55)
        AddToSection(reducedGroup, nil, 1)

        currentSection = nil

        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_frame", label = L["Frame"]},
            -- LEGACY-TEXT-CLEANUP: legacy text page hidden; link removed
            -- {pageId = "text_health", label = L["Health Text"]},
            {pageId = "bars_absorbs", label = L["Absorbs"]},
        }), 30, "both")
    end)
    
    -- Bars > Resource Bar
    local pageResource = CreateSubTab("bars", "bars_resource", L["Resource Bar"])
    BuildPage(pageResource, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"resourceBar"}, L["Resource Bar"], "bars_resource"), 25, 2)
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Resource Bar Settings"]), 40)
        local resourceBarEnable = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Resource Bar"], db, "resourceBarEnabled", function()
            DF:UpdateAllPowerEventRegistration()
            DF:UpdateAllFrames()
            self:RefreshStates()
        end), 30)
        resourceBarEnable.keepEnabled = true
        settingsGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Healers"], db, "resourceBarShowHealer", function() DF:UpdateAllFrames() end), 30)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Tanks"], db, "resourceBarShowTank", function() DF:UpdateAllFrames() end), 30)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["DPS"], db, "resourceBarShowDPS", function() DF:UpdateAllFrames() end), 30)
        local showInSolo = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show in Solo Mode"], db, "resourceBarShowInSoloMode", function() DF:UpdateAllFrames() end), 30)
        showInSolo.hideOn = function() return GUI.SelectedMode == "raid" end
        Add(settingsGroup, nil, 1)

        -- ===== CLASS FILTER GROUP (Column 1) =====
        local classFilterGroup = GUI:CreateSettingsGroup(self.child, 280)
        classFilterGroup:AddWidget(GUI:CreateHeader(self.child, L["Class Filter"]), 40)
        classFilterGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end

        local RB_CLASS_LIST = {
            { token = "WARRIOR",      name = L["Warrior"] },
            { token = "PALADIN",      name = L["Paladin"] },
            { token = "HUNTER",       name = L["Hunter"] },
            { token = "ROGUE",        name = L["Rogue"] },
            { token = "PRIEST",       name = L["Priest"] },
            { token = "DEATHKNIGHT",  name = L["Death Knight"] },
            { token = "SHAMAN",       name = L["Shaman"] },
            { token = "MAGE",         name = L["Mage"] },
            { token = "WARLOCK",      name = L["Warlock"] },
            { token = "MONK",         name = L["Monk"] },
            { token = "DRUID",        name = L["Druid"] },
            { token = "DEMONHUNTER",  name = L["Demon Hunter"] },
            { token = "EVOKER",       name = L["Evoker"] },
        }

        if not db.resourceBarClassFilter then
            db.resourceBarClassFilter = {}
            for _, info in ipairs(RB_CLASS_LIST) do
                db.resourceBarClassFilter[info.token] = true
            end
        end

        for _, info in ipairs(RB_CLASS_LIST) do
            classFilterGroup:AddWidget(
                GUI:CreateCheckbox(self.child, info.name, db.resourceBarClassFilter, info.token, function()
                    DF:UpdateAllFrames()
                end), 25
            )
        end
        Add(classFilterGroup, nil, 1)

        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        positionGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end

        local anchorOptions = {
            TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"], CENTER= L["Center"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "resourceBarAnchor", function() DF:UpdateAllFrames() end), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "resourceBarX", nil, function() DF:LightweightUpdatePowerBarPosition() end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "resourceBarY", nil, function() DF:LightweightUpdatePowerBarPosition() end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== TEXTURE GROUP (Column 1) — mirrors the Health Bar's Texture group:
        -- Texture, Orientation / Reverse Fill, and Smooth Bar Animation in one place. =====
        local textureGroup = GUI:CreateSettingsGroup(self.child, 280)
        textureGroup:AddWidget(GUI:CreateHeader(self.child, L["Texture"]), 40)
        textureGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        textureGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "resourceBarTexture", function() DF:UpdateAllFrames() end), 55)

        -- Keep Orientation (Horizontal/Vertical) and Reverse Fill as two explicit
        -- controls — clearer than a combined "Fill Direction" dropdown, where an
        -- option like "Bottom to Top" silently changes the orientation too.
        local orientOptions = { HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"] }
        textureGroup:AddWidget(GUI:CreateDropdown(self.child, L["Orientation"], orientOptions, db, "resourceBarOrientation", function() DF:UpdateAllFrames() end), 55)
        textureGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Fill Direction"], db, "resourceBarReverseFill", function() DF:UpdateAllFrames() end), 30)

        textureGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Smooth Bar Animation"], db, "resourceBarSmooth", function() DF:UpdateAllFrames() end), 30)
        Add(textureGroup, nil, 1)
        
        -- ===== BACKGROUND GROUP (Column 2) =====
        local bgGroup = GUI:CreateSettingsGroup(self.child, 280)
        bgGroup:AddWidget(GUI:CreateHeader(self.child, L["Background"]), 40)
        bgGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        bgGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Background"], db, "resourceBarBackgroundEnabled", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        local bgColor = bgGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "resourceBarBackgroundColor", true, nil, function() DF:LightweightUpdateResourceBarBackgroundColor() end, true), 35)
        bgColor.disableOn = function(d) return not d.resourceBarBackgroundEnabled end
        Add(bgGroup, nil, 2)
        
        -- ===== BORDER GROUP (Column 1) =====
        -- Stage 4.2: hand-rolled Show + Colour block expanded to the full
        -- unified helper. include set tailored for a resource indicator:
        -- alpha / inset / blendMode / gradient / shadow keep the visual
        -- toolkit; classColor / roleColor match the bar's optional class
        -- tinting (resourceBarClassColor) for cohesion. Skipped: animate
        -- (resource bar is decoration, not an alert surface), offset (bar
        -- has its own X/Y positioning controls above), colorByTime /
        -- colorByType (no aura-state context).
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        borderGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        GUI:CreateBorderControls(borderGroup, db, "resourceBar", {
            parent       = self.child,
            include      = { alpha = true, inset = true, blendMode = true,
                             gradient = true, shadow = true,
                             classColor = true, roleColor = true },
            fullUpdate   = function() DF:LightweightUpdateResourceBarBorder() end,
            lightUpdate  = function() DF:LightweightUpdateResourceBarBorder() end,
            lightColors  = function() DF:LightweightUpdateResourceBarBorderColor() end,
            refreshStates = function() self:RefreshStates() end,
            sizeMin = 1, sizeMax = 6, sizeStep = 1,
        })
        Add(borderGroup, nil, 1)
        
        -- ===== FRAME LEVEL GROUP (Column 2) =====
        local frameLevelGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameLevelGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Level"]), 40)
        frameLevelGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        frameLevelGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 20, 1, db, "resourceBarFrameLevel", nil, function() DF:LightweightUpdateResourceBarFrameLevel() end, true), 55)
        frameLevelGroup:AddWidget(GUI:CreateLabel(self.child, L["Higher values render the bar above other elements. Frame border is at level 10."], 250), 50)
        Add(frameLevelGroup, nil, 2)
        
        -- ===== SIZE GROUP (Column 1) =====
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Size"]), 40)
        sizeGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Match Health Bar Width/Height"], db, "resourceBarMatchWidth", function() DF:UpdateAllFrames() end), 30)
        local widthSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Width / Length"], 10, 200, 1, db, "resourceBarWidth", nil, function() DF:LightweightUpdatePowerBarSize() end, true), 55)
        widthSlider.disableOn = function(d) return d.resourceBarMatchWidth end
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Height / Thickness"], 1, 20, 1, db, "resourceBarHeight", nil, function() DF:LightweightUpdatePowerBarSize() end, true), 55)
        Add(sizeGroup, nil, 1)
        
        -- ===== RESOURCE COLORS GROUP (Column 2) =====
        local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorGroup:AddWidget(GUI:CreateHeader(self.child, L["Resource Colors"]), 40)
        colorGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        colorGroup:AddWidget(GUI:CreateLabel(self.child, L["Customize resource bar colors per power type. Shared across party and raid frames."], 260), 40)
        -- Colour mode: Power Type (per-power colours below) / Class / Custom.
        local RESOURCE_COLOR_MODES = {
            POWER_TYPE = L["Power Type"], CLASS = L["Class"], CUSTOM = L["Custom"],
            _order = { "POWER_TYPE", "CLASS", "CUSTOM" },
        }
        colorGroup:AddWidget(GUI:CreateDropdown(self.child, L["Color Mode"], RESOURCE_COLOR_MODES, db, "resourceBarColorMode", function()
            DF:RefreshAllVisibleFrames()
            self:RefreshStates()  -- re-evaluate the custom colour picker's hideOn
        end), 54)

        -- Custom colour — only shown in Custom mode.
        local resourceCustomColor = GUI:CreateColorPicker(self.child, L["Custom Color"], db, "resourceBarCustomColor", false, function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true)
        resourceCustomColor.hideOn = function() return (db.resourceBarColorMode or "POWER_TYPE") ~= "CUSTOM" end
        colorGroup:AddWidget(resourceCustomColor, 30)

        local powerColorsDB = DF.db.powerColors
        if not powerColorsDB then
            DF.db.powerColors = {}
            powerColorsDB = DF.db.powerColors
        end
        
        local POWER_LIST = {
            { token = "MANA",         name = L["Mana"] },
            { token = "RAGE",         name = L["Rage"] },
            { token = "FOCUS",        name = L["Focus"] },
            { token = "ENERGY",       name = L["Energy"] },
            { token = "RUNIC_POWER",  name = L["Runic Power"] },
            { token = "INSANITY",     name = L["Insanity"] },
            { token = "FURY",         name = L["Fury"] },
            { token = "PAIN",         name = L["Pain"] },
            { token = "LUNAR_POWER",  name = L["Lunar Power"] },
            { token = "MAELSTROM",    name = L["Maelstrom"] },
        }
        
        for _, info in ipairs(POWER_LIST) do
            local token = info.token
            if not powerColorsDB[token] then
                local default = PowerBarColor[token]
                if default then
                    powerColorsDB[token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            colorGroup:AddWidget(GUI:CreateColorPicker(self.child, info.name, powerColorsDB, token, false, function()
                DF:RefreshAllVisibleFrames()
            end, function()
                DF:RefreshAllVisibleFrames()
            end, true), 30)
        end
        
        -- Reset button
        local resetPowerBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        GUI:StyleButton(resetPowerBtn, { width = 260, height = 24, text = L["Reset All to Default"] })
        resetPowerBtn:SetScript("OnClick", function()
            for _, info in ipairs(POWER_LIST) do
                local default = PowerBarColor[info.token]
                if default then
                    powerColorsDB[info.token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            DF:RefreshAllVisibleFrames()
            if pageResource and pageResource.Refresh then
                pageResource:Refresh()
            end
        end)
        colorGroup:AddWidget(resetPowerBtn, 30)
        
        Add(colorGroup, nil, 2)
    end)
    
    -- Bars > Class Power (Holy Power, Chi, Combo Points, etc. - player frame only)
    local pageClassPower = CreateSubTab("bars", "bars_classpower", L["Class Power"])
    BuildPage(pageClassPower, function(self, db, Add, AddSpace, AddSyncPoint)
        Add(CreateCopyButton(self.child, {"classPower"}, L["Class Power"]), 25, 2)
        Add(GUI:CreateHeader(self.child, L["Class Power Pips"]), 40, "both")
        Add(GUI:CreateLabel(self.child, L["Displays class-specific resources (Holy Power, Chi, Combo Points, Soul Shards, Arcane Charges, Essence) as colored pips on your player frame."], 560), 50, "both")
        AddSpace(10, "both")
        
        Add(GUI:CreateCheckbox(self.child, L["Enable Class Power Pips"], db, "classPowerEnabled", function()
            self:RefreshStates()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end), 25, 1)
        
        -- Dependent controls GREY OUT (disabled-in-place) while the feature is
        -- off rather than vanishing. This is a flat page (no settings group),
        -- so each control carries disableOn; headers/spacers stay visible.
        local function DisableClassPower(d)
            return not d.classPowerEnabled
        end

        AddSpace(10, 1)
        Add(GUI:CreateHeader(self.child, L["Size"]), 40, 1)

        local cpHeight = Add(GUI:CreateSlider(self.child, L["Pip Height"], 1, 12, 1, db, "classPowerHeight", nil, function() if DF.RefreshClassPower then DF.RefreshClassPower() end end, true), 55, 1)
        cpHeight.disableOn = DisableClassPower

        local cpGap = Add(GUI:CreateSlider(self.child, L["Gap Between Pips"], 0, 5, 1, db, "classPowerGap", nil, function() if DF.RefreshClassPower then DF.RefreshClassPower() end end, true), 55, 1)
        cpGap.disableOn = DisableClassPower

        local cpIgnoreFade = Add(GUI:CreateCheckbox(self.child, L["Ignore Full Health Fade"], db, "classPowerIgnoreFade", function()
            if DF.UpdateClassPowerAlpha then DF.UpdateClassPowerAlpha() end
        end), 25, 1)
        cpIgnoreFade.disableOn = DisableClassPower

        AddSpace(10, 1)
        Add(GUI:CreateHeader(self.child, L["Colors"]), 40, 1)

        local cpUseCustomColor = Add(GUI:CreateCheckbox(self.child, L["Use Custom Pip Color"], db, "classPowerUseCustomColor", function()
            self:RefreshStates()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end), 25, 1)
        cpUseCustomColor.disableOn = DisableClassPower
        cpUseCustomColor.tooltip = L["When enabled, all pips use a single custom color instead of the class-specific default."]

        local cpColor = Add(GUI:CreateColorPicker(self.child, L["Pip Color"], db, "classPowerColor", false, function()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end, function()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end, true), 35, 1)
        cpColor.disableOn = function(d) return not d.classPowerEnabled or not d.classPowerUseCustomColor end

        local cpBgColor = Add(GUI:CreateColorPicker(self.child, L["Background Color"], db, "classPowerBgColor", true, function()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end, function()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end, true), 35, 1)
        cpBgColor.disableOn = DisableClassPower
        cpBgColor.tooltip = L["Color and opacity of the empty/inactive pips."]

        Add(GUI:CreateHeader(self.child, L["Position"]), 40, 2)
        local anchorOptions = {
            INSIDE_BOTTOM = L["Inside (Bottom)"],
            INSIDE_TOP = L["Inside (Top)"],
            BOTTOM = L["Below Health Bar"],
            TOP = L["Above Health Bar"],
            LEFT = L["Left of Health Bar"],
            RIGHT = L["Right of Health Bar"],
        }
        local cpAnchor = Add(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "classPowerAnchor", function() if DF.RefreshClassPower then DF.RefreshClassPower() end end), 55, 2)
        cpAnchor.disableOn = DisableClassPower
        cpAnchor.tooltip = L["Horizontal anchors lay pips left-to-right. Left/Right anchors stack pips vertically along the frame side."]

        local cpX = Add(GUI:CreateSlider(self.child, L["Offset X"], -30, 30, 1, db, "classPowerX", nil, function() if DF.RefreshClassPower then DF.RefreshClassPower() end end, true), 55, 2)
        cpX.disableOn = DisableClassPower

        local cpY = Add(GUI:CreateSlider(self.child, L["Offset Y"], -20, 20, 1, db, "classPowerY", nil, function() if DF.RefreshClassPower then DF.RefreshClassPower() end end, true), 55, 2)
        cpY.disableOn = DisableClassPower

        AddSpace(10, 2)
        Add(GUI:CreateHeader(self.child, L["Show for Roles"]), 40, 2)

        local cpShowTank = Add(GUI:CreateCheckbox(self.child, L["Tank"], db, "classPowerShowTank", function()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end), 25, 2)
        cpShowTank.disableOn = DisableClassPower

        local cpShowHealer = Add(GUI:CreateCheckbox(self.child, L["Healer"], db, "classPowerShowHealer", function()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end), 25, 2)
        cpShowHealer.disableOn = DisableClassPower

        local cpShowDamager = Add(GUI:CreateCheckbox(self.child, L["Damage"], db, "classPowerShowDamager", function()
            if DF.RefreshClassPower then DF.RefreshClassPower() end
        end), 25, 2)
        cpShowDamager.disableOn = DisableClassPower
    end)
    
    -- Bars > Absorbs (combined Absorb Shield + Heal Absorb with collapsible sections)
    local pageAbsorb = CreateSubTab("bars", "bars_absorb", L["Absorbs"])
    BuildPage(pageAbsorb, function(self, db, Add, AddSpace)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"absorbBar", "healAbsorb"}, L["Absorbs"], "bars_absorb"), 25, 2)
        
        local currentSection = nil
        
        -- Helper to add widgets to current section
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then
                currentSection:RegisterChild(widget)
            end
            return widget
        end
        
        -- ===== ABSORB SHIELD SECTION =====
        local absorbSection = Add(GUI:CreateCollapsibleSection(self.child, L["Absorb Shield"], true), 36, "both")
        currentSection = absorbSection
        
        local modeOptions = {
            OVERLAY = L["Overlay (on health bar)"],
            ATTACHED = L["Attached to Health"],
            ATTACHED_OVERFLOW = L["Attached + Overflow"],
            FLOATING = L["Floating Bar"],
        }
        AddToSection(GUI:CreateDropdown(self.child, L["Display Mode"], modeOptions, db, "absorbBarMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55, 1)
        
        local textureOptions = DF:GetTextureList()
        -- Add stripe textures if not already present
        local stripeTextures = {
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft"]= "DF Stripes Soft",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft_Wide"]= "DF Stripes Soft Wide",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes"]= "DF Stripes",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Sparse"]= "DF Stripes Sparse",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Medium"]= "DF Stripes Medium",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Dense"]= "DF Stripes Dense",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Very_Dense"]= "DF Stripes Very Dense",
        }
        for path, name in pairs(stripeTextures) do
            if not textureOptions[path] then
                textureOptions[path] = name
            end
        end
        AddToSection(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "absorbBarTexture", function() DF:UpdateAllFrames() end, textureOptions), 55, 1)
        
        AddToSection(GUI:CreateColorPicker(self.child, L["Bar Color"], db, "absorbBarColor", true, nil, function() DF:LightweightUpdateAbsorbBarColor() end, true), 35, 1)
        
        local blendOptions = { BLEND= L["Normal (BLEND)"], ADD= L["Additive (ADD)"] }
        AddToSection(GUI:CreateDropdown(self.child, L["Blend Mode"], blendOptions, db, "absorbBarBlendMode", function() DF:UpdateAllFrames() end), 55, 1)
        
        local overlayRev = AddToSection(GUI:CreateCheckbox(self.child, L["Reverse Overlay Fill"], db, "absorbBarOverlayReverse", function() DF:UpdateAllFrames() end), 25, 1)
        overlayRev.hideOn = function(d) return d.absorbBarMode ~= "OVERLAY" and d.absorbBarMode ~= "ATTACHED_OVERFLOW" end
        
        local absorbClampOptions = {
            [0] = L["None (no clamping)"],
            [1] = L["Missing Health"],
            [2] = L["Max Health"],
        }
        local absorbClampDropdown = AddToSection(GUI:CreateDropdown(self.child, L["Clamp Mode"], absorbClampOptions, db, "absorbBarAttachedClampMode", function() DF:UpdateAllFrames() end), 55, 1)
        absorbClampDropdown.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" and d.absorbBarMode ~= "ATTACHED_OVERFLOW" end
        
        local absorbShowOvershield = AddToSection(GUI:CreateCheckbox(self.child, L["Show Overshield Glow"], db, "absorbBarShowOvershield", function() DF:UpdateAllFrames() end), 25, 1)
        absorbShowOvershield.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
        absorbShowOvershield.tooltip = L["Shows a glow at max health when absorb exceeds the clamp limit."]
        
        local absorbOvershieldStyleOptions = {
            SPARK = L["Spark"],
            LINE = L["Line"],
            GRADIENT = L["Gradient"],
            GLOW = L["Glow"],
        }
        -- Overshield glow detail controls: HIDE for the wrong bar mode (variant), but
        -- GREY (disabled-in-place) when the boolean "Show Overshield Glow" toggle is off.
        local absorbOvershieldStyle = AddToSection(GUI:CreateDropdown(self.child, L["Glow Style"], absorbOvershieldStyleOptions, db, "absorbBarOvershieldStyle", function() DF:UpdateAllFrames() end), 55, 1)
        absorbOvershieldStyle.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
        absorbOvershieldStyle.disableOn = function(d) return not d.absorbBarShowOvershield end

        local absorbOvershieldColor = AddToSection(GUI:CreateColorPicker(self.child, L["Glow Color"], db, "absorbBarOvershieldColor", false, nil, function() DF:UpdateAllFrames() end), 35, 1)
        absorbOvershieldColor.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
        absorbOvershieldColor.disableOn = function(d) return not d.absorbBarShowOvershield end

        local absorbOvershieldAlpha = AddToSection(GUI:CreateSlider(self.child, L["Glow Alpha"], 0.1, 1, 0.05, db, "absorbBarOvershieldAlpha", nil, function() DF:UpdateAllFrames() end, true), 55, 1)
        absorbOvershieldAlpha.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
        absorbOvershieldAlpha.disableOn = function(d) return not d.absorbBarShowOvershield end

        local absorbOvershieldReverse = AddToSection(GUI:CreateCheckbox(self.child, L["Reverse Position"], db, "absorbBarOvershieldReverse", function() DF:UpdateAllFrames() end), 25, 1)
        absorbOvershieldReverse.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
        absorbOvershieldReverse.disableOn = function(d) return not d.absorbBarShowOvershield end
        absorbOvershieldReverse.tooltip = L["Moves the glow to the opposite side (no HP side instead of max HP side)."]
        
        -- Floating mode settings (column 2)
        local floatingHeader = AddToSection(GUI:CreateHeader(self.child, L["Floating Bar Position"]), 45, 2)
        floatingHeader.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local orientOptions = { HORIZONTAL= L["Horizontal"], VERTICAL= L["Vertical"] }
        local orientDropdown = AddToSection(GUI:CreateDropdown(self.child, L["Orientation"], orientOptions, db, "absorbBarOrientation", function() DF:UpdateAllFrames() end), 55, 1)
        orientDropdown.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local revFill = AddToSection(GUI:CreateCheckbox(self.child, L["Reverse Fill"], db, "absorbBarReverse", function() DF:UpdateAllFrames() end), 25, 2)
        revFill.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local widthSlider = AddToSection(GUI:CreateSlider(self.child, L["Width"], 10, 200, 1, db, "absorbBarWidth", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
        widthSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local heightSlider = AddToSection(GUI:CreateSlider(self.child, L["Height"], 1, 30, 1, db, "absorbBarHeight", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
        heightSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local anchorOptions = {
            TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"], CENTER= L["Center"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        local anchorDropdown = AddToSection(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "absorbBarAnchor", function() DF:UpdateAllFrames() end), 55, 1)
        anchorDropdown.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local xSlider = AddToSection(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "absorbBarX", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
        xSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local ySlider = AddToSection(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "absorbBarY", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
        ySlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local bgColorPicker = AddToSection(GUI:CreateColorPicker(self.child, L["Background Color"], db, "absorbBarBackgroundColor", true, nil, function() DF:LightweightUpdateAbsorbBarColor() end, true), 35, 2)
        bgColorPicker.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local strataOptions = {
            BACKGROUND = L["Background"],
            LOW = L["Low"],
            MEDIUM = L["Medium"],
            HIGH = L["High"],
            DIALOG = L["Dialog"],
        }
        local strataDropdown = AddToSection(GUI:CreateDropdown(self.child, L["Frame Strata"], strataOptions, db, "absorbBarStrata", function() DF:UpdateAllFrames() end), 55, 1)
        strataDropdown.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local levelSlider = AddToSection(GUI:CreateSlider(self.child, L["Frame Level"], 1, 100, 1, db, "absorbBarFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("absorb") end, true), 55, 1)
        levelSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== HEAL ABSORB SECTION =====
        local healAbsorbSection = Add(GUI:CreateCollapsibleSection(self.child, L["Heal Absorb"], true), 36, "both")
        currentSection = healAbsorbSection
        
        AddToSection(GUI:CreateLabel(self.child, L["Shows effects that reduce incoming healing (like Necrotic stacks)."], 260), 25, 1)
        
        local healModeOptions = {
            OVERLAY = L["Overlay (on health bar)"],
            ATTACHED = L["Attached to Health"],
            FLOATING = L["Floating Bar"],
        }
        AddToSection(GUI:CreateDropdown(self.child, L["Display Mode"], healModeOptions, db, "healAbsorbBarMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55, 1)
        
        local healTextureOptions = DF:GetTextureList()
        -- Add stripe textures if not already present
        local healStripeTextures = {
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft"]= "DF Stripes Soft",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft_Wide"]= "DF Stripes Soft Wide",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes"]= "DF Stripes",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Sparse"]= "DF Stripes Sparse",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Medium"]= "DF Stripes Medium",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Dense"]= "DF Stripes Dense",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Very_Dense"]= "DF Stripes Very Dense",
        }
        for path, name in pairs(healStripeTextures) do
            if not healTextureOptions[path] then
                healTextureOptions[path] = name
            end
        end
        AddToSection(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "healAbsorbBarTexture", function() DF:UpdateAllFrames() end, healTextureOptions), 55, 1)
        
        AddToSection(GUI:CreateColorPicker(self.child, L["Bar Color"], db, "healAbsorbBarColor", true, nil, function() DF:LightweightUpdateHealAbsorbBarColor() end, true), 35, 1)
        
        local healBlendOptions = { BLEND= L["Normal (BLEND)"], ADD= L["Additive (ADD)"] }
        AddToSection(GUI:CreateDropdown(self.child, L["Blend Mode"], healBlendOptions, db, "healAbsorbBarBlendMode", function() DF:UpdateAllFrames() end), 55, 1)
        
        local healOverlayRev = AddToSection(GUI:CreateCheckbox(self.child, L["Reverse Overlay Fill"], db, "healAbsorbBarOverlayReverse", function() DF:UpdateAllFrames() end), 25, 1)
        healOverlayRev.hideOn = function(d) return d.healAbsorbBarMode ~= "OVERLAY" end
        
        -- Heal Absorb Floating mode settings (column 2)
        local healFloatingHeader = AddToSection(GUI:CreateHeader(self.child, L["Floating Bar Position"]), 45, 2)
        healFloatingHeader.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healOrientDropdown = AddToSection(GUI:CreateDropdown(self.child, L["Orientation"], orientOptions, db, "healAbsorbBarOrientation", function() DF:UpdateAllFrames() end), 55, 1)
        healOrientDropdown.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healRevFill = AddToSection(GUI:CreateCheckbox(self.child, L["Reverse Fill"], db, "healAbsorbBarReverse", function() DF:UpdateAllFrames() end), 25, 2)
        healRevFill.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healWidthSlider = AddToSection(GUI:CreateSlider(self.child, L["Width"], 10, 200, 1, db, "healAbsorbBarWidth", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
        healWidthSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healHeightSlider = AddToSection(GUI:CreateSlider(self.child, L["Height"], 1, 30, 1, db, "healAbsorbBarHeight", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
        healHeightSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healAnchorDropdown = AddToSection(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "healAbsorbBarAnchor", function() DF:UpdateAllFrames() end), 55, 1)
        healAnchorDropdown.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healXSlider = AddToSection(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "healAbsorbBarX", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
        healXSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healYSlider = AddToSection(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "healAbsorbBarY", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
        healYSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healBgColorPicker = AddToSection(GUI:CreateColorPicker(self.child, L["Background Color"], db, "healAbsorbBarBackgroundColor", true, nil, function() DF:LightweightUpdateHealAbsorbBarColor() end, true), 35, 2)
        healBgColorPicker.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        currentSection = nil
    end)
    
    -- Bars > Heal Prediction
    local pageHealPrediction = CreateSubTab("bars", "bars_healpred", L["Heal Prediction"])
    BuildPage(pageHealPrediction, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"healPrediction"}, L["Heal Prediction"], "bars_healpred"), 25, 2)
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Heal Prediction"]), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Heal Prediction"], db, "healPredictionEnabled", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)

        local overhealCheckbox = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Overheal"], db, "healPredictionShowOverheal", function() DF:UpdateAllFrames() end), 30)
        overhealCheckbox.disableOn = function(d) return not d.healPredictionEnabled end
        overhealCheckbox.tooltip = L["When enabled, shows incoming heals even if they would overheal."]

        local modeOptions = { OVERLAY= L["Attached to Health"], FLOATING= L["Floating Bar"] }
        local modeDropdown = settingsGroup:AddWidget(GUI:CreateDropdown(self.child, L["Display Mode"], modeOptions, db, "healPredictionMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55)
        modeDropdown.disableOn = function(d) return not d.healPredictionEnabled end

        local showModeOptions = {
            ALL = L["All Incoming"], MINE = L["My Heals"], OTHERS = L["Others' Heals"],
            SPLIT = L["Split (Mine + Others)"],
            _order = { "ALL", "MINE", "OTHERS", "SPLIT" },
        }
        local showModeDropdown = settingsGroup:AddWidget(GUI:CreateDropdown(self.child, L["Show Heals From"], showModeOptions, db, "healPredictionShowMode", function()
            -- Rebuild so the colour picker(s) rebind to the selected mode.
            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            DF:UpdateAllFrames()
        end), 55)
        showModeDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        showModeDropdown.tooltip = L["Which incoming heals the bar shows: all sources, only yours, or only from others."]

        local textureOptions = DF:GetTextureList()
        local texDropdown = settingsGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "healPredictionTexture", function() DF:UpdateAllFrames() end, textureOptions), 55)
        texDropdown.disableOn = function(d) return not d.healPredictionEnabled end

        -- Colour picker(s): Split shows both segment colours; other modes show
        -- the single colour for the selected mode. The mode dropdown rebuilds
        -- the page so these rebind when the mode changes.
        if db.healPredictionShowMode == "SPLIT" then
            local myColor = settingsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["My Heals Color"], db, "healPredictionMyColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
            myColor.disableOn = function(d) return not d.healPredictionEnabled end
            local othersColor = settingsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Others' Heals Color"], db, "healPredictionOthersColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
            othersColor.disableOn = function(d) return not d.healPredictionEnabled end
        else
            local showModeColorKey = (db.healPredictionShowMode == "ALL" and "healPredictionAllColor")
                or (db.healPredictionShowMode == "OTHERS" and "healPredictionOthersColor")
                or "healPredictionMyColor"
            local myColor = settingsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Heal Prediction Color"], db, showModeColorKey, true, nil, function() DF:UpdateAllFrames() end, true), 35)
            myColor.disableOn = function(d) return not d.healPredictionEnabled end
        end

        local blendOptions = { BLEND= L["Normal (BLEND)"], ADD= L["Additive (ADD)"] }
        local blendDropdown = settingsGroup:AddWidget(GUI:CreateDropdown(self.child, L["Blend Mode"], blendOptions, db, "healPredictionBlendMode", function() DF:UpdateAllFrames() end), 55)
        blendDropdown.disableOn = function(d) return not d.healPredictionEnabled end

        Add(settingsGroup, nil, 1)


        -- ===== FLOATING POSITION GROUP (Column 1, conditional) =====
        local floatingGroup = GUI:CreateSettingsGroup(self.child, 280)
        floatingGroup:AddWidget(GUI:CreateHeader(self.child, L["Floating Bar Position"]), 40)
        
        local orientOptions = { HORIZONTAL= L["Horizontal"], VERTICAL= L["Vertical"] }
        local orientDropdown = floatingGroup:AddWidget(GUI:CreateDropdown(self.child, L["Orientation"], orientOptions, db, "healPredictionOrientation", function() DF:UpdateAllFrames() end), 55)
        orientDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        
        local revFill = floatingGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Fill"], db, "healPredictionReverse", function() DF:UpdateAllFrames() end), 30)
        revFill.disableOn = function(d) return not d.healPredictionEnabled end
        
        local widthSlider = floatingGroup:AddWidget(GUI:CreateSlider(self.child, L["Width"], 10, 200, 1, db, "healPredictionWidth", nil, function() DF:UpdateAllFrames() end, true), 55)
        widthSlider.disableOn = function(d) return not d.healPredictionEnabled end
        
        local heightSlider = floatingGroup:AddWidget(GUI:CreateSlider(self.child, L["Height"], 1, 30, 1, db, "healPredictionHeight", nil, function() DF:UpdateAllFrames() end, true), 55)
        heightSlider.disableOn = function(d) return not d.healPredictionEnabled end
        
        floatingGroup.hideOn = function(d) return d.healPredictionMode ~= "FLOATING" end
        Add(floatingGroup, nil, 1)
        
        -- ===== FLOATING ANCHOR GROUP (Column 2, conditional) =====
        local anchorGroup = GUI:CreateSettingsGroup(self.child, 280)
        anchorGroup:AddWidget(GUI:CreateHeader(self.child, L["Floating Bar Anchor"]), 40)
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        local anchorDropdown = anchorGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "healPredictionAnchor", function() DF:UpdateAllFrames() end), 55)
        anchorDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        
        local xSlider = anchorGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "healPredictionX", nil, function() DF:UpdateAllFrames() end, true), 55)
        xSlider.disableOn = function(d) return not d.healPredictionEnabled end
        
        local ySlider = anchorGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "healPredictionY", nil, function() DF:UpdateAllFrames() end, true), 55)
        ySlider.disableOn = function(d) return not d.healPredictionEnabled end
        
        local bgColorPicker = anchorGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "healPredictionBackgroundColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
        bgColorPicker.disableOn = function(d) return not d.healPredictionEnabled end
        
        anchorGroup.hideOn = function(d) return d.healPredictionMode ~= "FLOATING" end
        Add(anchorGroup, nil, 2)
    end)
    
    -- ========================================
    -- CATEGORY: Text
    -- ========================================
    CreateCategory("text", L["Text"])
    
    -- LEGACY-TEXT-CLEANUP (v4.4.x): Name/Health/Status built-in text settings are
    -- replaced by the Text Designer. These three pages are hidden via `if false`
    -- (not deleted, so they can be restored). Remove this block, the legacy text
    -- render path (see DF:IsLegacyTextHidden in Frames/Core.lua), and the legacy
    -- *Text* defaults in Config.lua in a future release once the Text Designer
    -- fully supersedes them.
    if false then
    -- Text > Health Text
    local pageHealthText = CreateSubTab("text", "text_health", L["Health Text"])
    BuildPage(pageHealthText, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"healthText", "healthFont"}, L["Health Text"], "text_health"), 25, 2)
        
        -- ===== FORMAT GROUP (Column 1) =====
        local formatGroup = GUI:CreateSettingsGroup(self.child, 280)
        formatGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Text"]), 40)
        
        local formatOptions = {
            PERCENT= L["Percentage"], CURRENT= L["Current Health"], CURRENTMAX= L["Current / Max"],
            DEFICIT= L["Health Deficit"], NONE= L["Hidden"],
            _order = {"PERCENT", "CURRENT", "CURRENTMAX", "DEFICIT", "NONE"},
        }
        formatGroup:AddWidget(GUI:CreateDropdown(self.child, L["Health Format"], formatOptions, db, "healthTextFormat", function() DF:RefreshAllVisibleFrames() end), 55)
        formatGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Abbreviate (K/M)"], db, "healthTextAbbreviate", function() DF:RefreshAllVisibleFrames() end), 30)
        formatGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide % Symbol"], db, "healthTextHidePercent", function() DF:RefreshAllVisibleFrames() end), 30)
        Add(formatGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "healthTextAnchor", function() DF:UpdateAllFrames() end), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "healthTextX", nil, function() DF:LightweightUpdateTextPosition("health") end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "healthTextY", nil, function() DF:LightweightUpdateTextPosition("health") end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== FONT GROUP (Column 1) =====
        local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontGroup:AddWidget(GUI:CreateHeader(self.child, L["Font"]), 40)
        fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "healthFont", function() DF:UpdateAllFrames() end), 55)
        fontGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 24, 1, db, "healthFontSize", nil, function() DF:LightweightUpdateFontSize("health") end, true), 55)
        
        fontGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "healthTextOutline", function() DF:LightweightUpdateFontSize("health") end), 55)
        fontGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "healthTextOutline", function() DF:LightweightUpdateFontSize("health") end), 30)
        fontGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "healthTextUseClassColor", function()
            self:RefreshStates()
            DF:RefreshAllVisibleFrames()
        end), 30)
        local healthColor = fontGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Text Color"], db, "healthTextColor", true, nil, function() DF:LightweightUpdateTextColor("health") end, true), 35)
        healthColor.disableOn = function(d) return d.healthTextUseClassColor end
        Add(fontGroup, nil, 1)
    end)
    
    -- Text > Status Text (Dead/Offline)
    local pageStatusText = CreateSubTab("text", "text_status", L["Status Text"])
    BuildPage(pageStatusText, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"statusText"}, L["Status Text"], "text_status"), 25, 2)
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Status Text (Dead/Offline)"]), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Status Text"], db, "statusTextEnabled", function() 
            -- Force full refresh of all frames to update status text visibility
            if DF.testMode or DF.raidTestMode then
                -- In test mode, refresh test frames
                if DF.RefreshTestFrames then DF:RefreshTestFrames() end
                if DF.UpdateRaidTestFrames then DF:UpdateRaidTestFrames() end
            else
                -- Live mode - update live frames
                if DF.IterateAllFrames then
                    DF:IterateAllFrames(function(frame)
                        if frame and frame.unit and UnitExists(frame.unit) then
                            DF:UpdateUnitFrame(frame)
                        end
                    end)
                end
            end
        end), 30)
        Add(settingsGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "statusTextAnchor", function() DF:UpdateAllFrames() end), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "statusTextX", nil, function() DF:LightweightUpdateTextPosition("status") end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "statusTextY", nil, function() DF:LightweightUpdateTextPosition("status") end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== FONT GROUP (Column 1) =====
        local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontGroup:AddWidget(GUI:CreateHeader(self.child, L["Font"]), 40)
        fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "statusTextFont", function() DF:UpdateAllFrames() end), 55)
        fontGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 24, 1, db, "statusTextFontSize", nil, function() DF:LightweightUpdateFontSize("status") end, true), 55)
        
        fontGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "statusTextOutline", function() DF:LightweightUpdateFontSize("status") end), 55)
        fontGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "statusTextOutline", function() DF:LightweightUpdateFontSize("status") end), 30)
        fontGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Text Color"], db, "statusTextColor", true, nil, function() DF:LightweightUpdateTextColor("status") end, true), 35)
        Add(fontGroup, nil, 1)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "display_fading", label = L["Dead/Offline Fading"]},
        }), 30, "both")
    end)
    
    -- Text > Name Text
    local pageNameText = CreateSubTab("text", "text_name", L["Name Text"])
    BuildPage(pageNameText, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"name"}, L["Name Text"], "text_name"), 25, 2)
        
        -- ===== FONT GROUP (Column 1) =====
        local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontGroup:AddWidget(GUI:CreateHeader(self.child, L["Name Text"]), 40)
        fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "nameFont", nil), 55)
        fontGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 24, 1, db, "nameFontSize", nil, function() DF:LightweightUpdateFontSize("name") end, true), 55)
        
        fontGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "nameTextOutline", function() DF:LightweightUpdateFontSize("name") end), 55)
        fontGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "nameTextOutline", function() DF:LightweightUpdateFontSize("name") end), 30)
        Add(fontGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "nameTextAnchor", nil), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "nameTextX", nil, function() DF:LightweightUpdateTextPosition("name") end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "nameTextY", nil, function() DF:LightweightUpdateTextPosition("name") end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== COLOR GROUP (Column 1) =====
        local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorGroup:AddWidget(GUI:CreateHeader(self.child, L["Color"]), 40)
        colorGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "nameTextUseClassColor", function()
            self:RefreshStates()
            DF:RefreshAllVisibleFrames()
        end), 30)
        local nameColor = colorGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Name Text Color"], db, "nameTextColor", true, nil, function() DF:LightweightUpdateTextColor("name") end, true), 35)
        nameColor.disableOn = function(d) return d.nameTextUseClassColor end
        Add(colorGroup, nil, 1)
        
        -- ===== TRUNCATION GROUP (Column 2) =====
        local truncGroup = GUI:CreateSettingsGroup(self.child, 280)
        truncGroup:AddWidget(GUI:CreateHeader(self.child, L["Truncation"]), 40)
        truncGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Length (0=off)"], 0, 20, 1, db, "nameTextLength", function()
            self:RefreshStates()
            DF:RefreshAllVisibleFrames()
        end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        
        local truncOptions = { ELLIPSIS= L["Ellipsis (...)"], CUT= L["Cut"] }
        local truncDropdown = truncGroup:AddWidget(GUI:CreateDropdown(self.child, L["Truncate Mode"], truncOptions, db, "nameTextTruncateMode", function() DF:RefreshAllVisibleFrames() end), 55)
        truncDropdown.disableOn = function(d) return (d.nameTextLength or 0) == 0 end
        Add(truncGroup, nil, 2)
    end)
    end -- LEGACY-TEXT-CLEANUP: end hidden legacy Name/Health/Status text pages

    -- Text > Text Designer
    -- See spec at docs/superpowers/specs/2026-05-22-text-designer-phase1-design.md
    local pageTextDesigner = CreateSubTab("text", "text_designer", L["Text Designer"])
    BuildPage(pageTextDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        if DF.BuildTextDesignerPage then
            DF.BuildTextDesignerPage(GUI, self, db)
        end
    end)

    -- ========================================
    -- CATEGORY: Auras
    -- ========================================
    CreateCategory("auras", L["Auras"])

    -- Auras > Aura Filters (master switch for Blizzard vs Direct API mode)
    local pageAuraFilters = CreateSubTab("auras", "auras_filters", L["Aura Filters"])
    BuildPage(pageAuraFilters, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Setup wizard banner: guided walkthrough of the aura filters.
        do
            local banner = GUI:CreateInfoBanner(self.child, { tone = "info" })
            banner:SetText(L["Having trouble with buffs or debuffs? Run the setup wizard for guided help."])
            -- Reserve room on the right for the action button (the banner body
            -- otherwise anchors to RIGHT -12 and would slide under it).
            banner.body:SetPoint("RIGHT", banner, "RIGHT", -110, 0)

            local bannerBtn = GUI:CreateButton(banner, L["Run Setup Wizard"], 105, 28, function()
                if DF.WizardBuilder then
                    local builtins = DF.WizardBuilder:GetBuiltinWizards()
                    for _, entry in ipairs(builtins) do
                        if entry.name == "Aura Filter Setup" and entry.build then
                            local config = entry.build()
                            if config then DF:ShowPopupWizard(config) end
                            break
                        end
                    end
                end
            end)
            bannerBtn:SetPoint("RIGHT", -8, 0)

            Add(banner, 50, "both")
            AddSpace(4, "both")
        end

        -- Copy button at top
        Add(CreateCopyButton(self.child, {"directBuff", "directDebuff"}, L["Aura Filters"], "auras_filters"), 25, 2)

        -- ===== INFO BANNER =====
        -- Explains that Aura Filters only affect buff/debuff bars, with inline
        -- links to related pages so users can find the independent systems.
        do
            local tc = GUI.GetThemeColor()
            local linkColor = string.format("|cFF%02X%02X%02X",
                math.floor((tc.r or 1) * 255),
                math.floor((tc.g or 1) * 255),
                math.floor((tc.b or 1) * 255))
            local function L_link(text, pageId)
                return linkColor .. "|HdfPage:" .. pageId .. "|h" .. text .. "|h|r"
            end
            local bodyText = L["Aura Filters only affect the"] .. " "
                .. L_link(L["Buff Bar"], "auras_buffs") .. " "
                .. L["and"] .. " "
                .. L_link(L["Debuff Bar"], "auras_debuffs") .. "."
                .. "\n"
                .. L["Auras displayed in the"] .. " "
                .. L_link(L["Dispel Overlay"], "auras_dispel") .. ", "
                .. L_link(L["Defensive Icon"], "auras_defensiveicon") .. ", "
                .. L["and"] .. " "
                .. L_link(L["Aura Designer"], "auras_auradesigner") .. " "
                .. L["are independent of Aura Filters."]

            local infoBanner = GUI:CreateInfoBanner(self.child, {
                tone = "info",
                html = true,
                text = bodyText,
                onLinkClick = function(pageId)
                    if GUI.SelectTab then GUI.SelectTab(pageId) end
                end,
                minHeight = 56,
            })
            Add(infoBanner, infoBanner.layoutHeight, "both")
            AddSpace(4, "both")
        end

        -- Callback that rebuilds the native filter strings and re-drives the
        -- container rows (they rebuild when their filter signature changes).
        local function DirectFilterChanged()
            if DF.RebuildDirectFilterStrings then
                DF:RebuildDirectFilterStrings()
            end
            if DF.InvalidateAuraLayout then
                DF:InvalidateAuraLayout()
            end
        end

        -- ===== BUFF FILTERS (Column 2, Direct mode only) =====
        local function HideBuffSubFilters(d)
            return d.directBuffShowAll
        end

        local buffGroup = GUI:CreateSettingsGroup(self.child, 280)
        local buffHeader = buffGroup:AddWidget(GUI:CreateHeader(self.child, L["Buff Filters"]), 40)

        local bfAll = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["All Buffs"], db, "directBuffShowAll", function()
            DirectFilterChanged()
            self:RefreshStates()
        end), 30)
        bfAll.tooltip = L["Show every buff with no filtering."]

        local bfOnlyMine = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Only My Buffs"], db, "directBuffOnlyMine", function()
            DirectFilterChanged()
            self:RefreshStates()
        end), 30)
        bfOnlyMine.tooltip = L["Only show buffs that you cast. Applies to all buff filters."]

        local buffSubInfo = buffGroup:AddWidget(GUI:CreateLabel(self.child, "|cff888888" .. L["Enabled filters are combined \226\128\148 buffs matching any selected filter will be shown."] .. "|r", 250), 35)
        buffSubInfo.hideOn = HideBuffSubFilters

        local bfRaid = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Raid Buffs"], db, "directBuffFilterRaid", DirectFilterChanged), 30)
        bfRaid.hideOn = HideBuffSubFilters
        bfRaid.tooltip = L["Buffs flagged by Blizzard to show up on raid frames."]

        local bfRaidIC = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Raid In Combat"], db, "directBuffFilterRaidInCombat", DirectFilterChanged), 30)
        bfRaidIC.hideOn = HideBuffSubFilters
        bfRaidIC.tooltip = L["Buffs flagged to show on raid frames during combat, such as self-cast HoTs."]

        local bfCancel = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Cancelable"], db, "directBuffFilterCancelable", DirectFilterChanged), 30)
        bfCancel.hideOn = HideBuffSubFilters
        bfCancel.tooltip = L["Buffs that can be right-click cancelled."]

        local bfNotCancel = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Not Cancelable"], db, "directBuffFilterNotCancelable", DirectFilterChanged), 30)
        bfNotCancel.hideOn = HideBuffSubFilters
        bfNotCancel.tooltip = L["Buffs that cannot be cancelled by the player."]

        local bfBigDef = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Big Defensives"], db, "directBuffFilterBigDefensive", DirectFilterChanged), 30)
        bfBigDef.hideOn = HideBuffSubFilters
        bfBigDef.tooltip = L["Major defensive cooldowns like Divine Shield, Ice Block, or Barkskin."]

        local bfExtDef = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["External Defensives"], db, "directBuffFilterExternalDefensive", DirectFilterChanged), 30)
        bfExtDef.hideOn = HideBuffSubFilters
        bfExtDef.tooltip = L["Defensive buffs from other players, like Pain Suppression or Blessing of Sacrifice."]

        local buffSortOptions = {
            DEFAULT = L["Default (Slot Order)"],
            TIME = L["Time Remaining"],
            NAME = L["Alphabetical"],
        }
        -- Sort works on BOTH paths: legacy rows sort in the Lua scan; factory rows map
        -- the same key onto the native AuraContainerSortMethod (TIME -> ExpirationOnly,
        -- NAME -> NameOnly) declared at AddAuraGroup — see BuildAuraRowConfig. (The
        -- 12.1 frost this control used to carry was lifted once the native mapping landed.)
        local bfSort = buffGroup:AddWidget(GUI:CreateDropdown(self.child, L["Sort Order"], buffSortOptions, db, "directBuffSortOrder", DirectFilterChanged), 55)

        -- Native-only: max TOTAL duration filter (12.1 candidateFilters.maxDuration).
        -- Hidden while the legacy render owns the row (not expressible there).
        local bfMaxDur = buffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Long Buffs"], db, "buffMaxDurationEnabled", function()
            DirectFilterChanged()
            self:RefreshStates()
        end), 30)
        bfMaxDur.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
        bfMaxDur.tooltip = L["Hide buffs whose total duration is longer than the threshold - e.g. hour-long food and flask buffs. Buffs with no duration (permanent auras) are also hidden while this is on."]
        local bfMaxDurSlider = buffGroup:AddWidget(GUI:CreateSlider(self.child, L["Hide Longer Than (minutes)"], 1, 30, 1, db, "buffMaxDurationMinutes", nil, DirectFilterChanged), 55)
        bfMaxDurSlider.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
        bfMaxDurSlider.disableOn = function(d) return not d.buffMaxDurationEnabled end
        Add(buffGroup, nil, 2)

        -- ===== DEBUFF FILTERS (Column 1, Direct mode only) =====
        local function HideDebuffSubFilters(d)
            return d.directDebuffShowAll
        end

        local debuffGroup = GUI:CreateSettingsGroup(self.child, 280)
        local debuffHeader = debuffGroup:AddWidget(GUI:CreateHeader(self.child, L["Debuff Filters"]), 40)

        local dfAll = debuffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["All Debuffs"], db, "directDebuffShowAll", function()
            DirectFilterChanged()
            self:RefreshStates()
        end), 30)
        dfAll.tooltip = L["Show every debuff with no filtering."]

        -- ===== WARNING BANNER: All Debuffs disabled =====
        local debuffWarningBanner = GUI:CreateInfoBanner(self.child, {
            tone = "info",
            text = L["Recommended: enable 'All Debuffs' to see all relevant debuffs, especially for healers."],
        })
        debuffWarningBanner.hideOn = function(d)
            return d.directDebuffShowAll
        end
        debuffGroup:AddWidget(debuffWarningBanner, debuffWarningBanner.layoutHeight)

        local debuffSubInfo = debuffGroup:AddWidget(GUI:CreateLabel(self.child, "|cff888888" .. L["Enabled filters are combined \226\128\148 debuffs matching any selected filter will be shown."] .. "|r", 250), 35)
        debuffSubInfo.hideOn = HideDebuffSubFilters

        local dfRaid = debuffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Raid Debuffs"], db, "directDebuffFilterRaid", DirectFilterChanged), 30)
        dfRaid.hideOn = HideDebuffSubFilters
        dfRaid.tooltip = L["Debuffs relevant in a raid context."]

        local dfRaidIC = debuffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Raid In Combat"], db, "directDebuffFilterRaidInCombat", DirectFilterChanged), 30)
        dfRaidIC.hideOn = HideDebuffSubFilters
        dfRaidIC.tooltip = L["Debuffs relevant during combat in a raid context."]

        local dfCC = debuffGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Crowd Control"], db, "directDebuffFilterCrowdControl", DirectFilterChanged), 30)
        dfCC.hideOn = HideDebuffSubFilters
        dfCC.tooltip = L["CC effects like stuns, roots, and incapacitates."]

        local dfDispelToggle = debuffGroup:AddWidget(GUI:CreateToggleSwitch(self.child, L["Dispellable By Me"], L["All Dispellable"], db, "directDebuffDispellableMode", "PLAYER", "ALL", DirectFilterChanged), 30)
        dfDispelToggle.hideOn = HideDebuffSubFilters
        dfDispelToggle.tooltip = L["Dispellable By Me: only debuffs you can dispel. All Dispellable: any debuff that can be dispelled."]

        local debuffSortOptions = {
            DEFAULT = L["Default (Slot Order)"],
            TIME = L["Time Remaining"],
            NAME = L["Alphabetical"],
        }
        local dfSort = debuffGroup:AddWidget(GUI:CreateDropdown(self.child, L["Sort Order"], debuffSortOptions, db, "directDebuffSortOrder", DirectFilterChanged), 55)
        Add(debuffGroup, nil, 1)
        -- 12.1: debuff filters + sort feed the factory row natively (P3). Blocked
        -- only when the 12.1 aura system is active but the factory is toggled off.
        GUI:BlockControl12_1(debuffGroup, "roadmap", { id = "filters:debuffgroup", page = L["Aura Filters"],
            when = function(d) return GUI:IsAuraFactoryActive() and not DF:FactoryOwnsDebuffRow(d) end })

        -- ===== AURA BLACKLIST (Column 2, under Buff Filters) =====
        -- Pointer section directing users to the dedicated Aura Blacklist tab.
        -- Aura Filters (this tab) controls what types of auras are shown;
        -- the Aura Blacklist tab is where specific spells are excluded.
        do
            local blacklistGroup = GUI:CreateSettingsGroup(self.child, 280)
            blacklistGroup:AddWidget(GUI:CreateHeader(self.child, L["Aura Blacklist"]), 40)

            local blacklistBanner = GUI:CreateInfoBanner(self.child, {tone = "info"})
            blacklistBanner:SetHTML(
                L["To blacklist specific auras, see the Aura Blacklist tab."] .. " " ..
                "|cffffffff|HopenBlacklist|h" .. L["Open Aura Blacklist"] .. "|h|r",
                function()
                    if GUI.SelectTab then GUI.SelectTab("auras_blacklist") end
                end)
            blacklistGroup:AddWidget(blacklistBanner, 64)

            Add(blacklistGroup, nil, 2)
        end

        -- ===== SEE ALSO =====
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buff Icons"]},
            {pageId = "auras_debuffs", label = L["Debuff Icons"]},
            {pageId = "auras_blacklist", label = L["Aura Blacklist"]},
            {pageId = "auras_auradesigner", label = L["Aura Designer"]},
        }), 30, "both")
    end)

    -- Auras > Aura Designer
    local pageAuraDesigner = CreateSubTab("auras", "auras_auradesigner", L["Aura Designer"])
    -- 12.1: the Aura Designer is being rebuilt on the native aura container.
    -- Unblock the page once the factory owns AD (mirrors the Debuffs/Missing Buffs
    -- pages); per-control API-limit overlays for the not-yet-portable settings land
    -- in the P4.7 GUI pass.
    GUI:BlockPage12_1(pageAuraDesigner, "roadmap", function(d)
        return GUI:IsAuraFactoryActive() and not DF:FactoryOwnsAD(d)
    end)
    BuildPage(pageAuraDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        if DF.BuildAuraDesignerPage then
            DF.BuildAuraDesignerPage(GUI, self, db)
        end
    end)

    -- Auras > Aura Blacklist
    local pageAuraBlacklist = CreateSubTab("auras", "auras_blacklist", L["Aura Blacklist"])
    -- 12.1: UN-BLOCKED (the original "include-only filters" premise was wrong for buffs —
    -- candidateFilters.excludeSpellIDs works for helpful auras on friendly frames and is
    -- now wired into the factory buff row via BuildAuraRowConfig). The DEBUFF half of the
    -- blacklist IS still dead on friendly frames (harmful spell-ID filters only apply to
    -- attackable units) — that gets a per-section note when the debuff row ports (P3).
    -- Split combat/OOC-only entries can't be expressed statically and stay visible on
    -- factory rows (only always-blacklisted entries are excluded).
    -- GUI:BlockPage12_1(pageAuraBlacklist, "limitation")
    BuildPage(pageAuraBlacklist, function(self, db, Add, AddSpace, AddSyncPoint)
        if DF.BuildAuraBlacklistPage then
            DF.BuildAuraBlacklistPage(GUI, self, db)
        end
    end)

    -- Auras > Buffs (combined Layout + Appearance with collapsible sections)
    local pageBuffs = CreateSubTab("auras", "auras_buffs", L["Buffs"])
    BuildPage(pageBuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- ========================================
        -- AD COEXISTENCE INFO BANNER
        -- Shows when Aura Designer is active (with or without buffs).
        -- ========================================
        local adBanner = GUI:CreateInfoBanner(self.child, {tone = "info"})

        -- Link markup helper: |cCOLOR|HlinkData|hText|h|r — the banner recolours
        -- links via the theme, so the markup colour is only a placeholder.
        local function adLink(data, text)
            return "|cffffffff|H" .. data .. "|h" .. text .. "|h|r"
        end
        local function adOnLink(data)
            if data == "enableBuffs" then
                db.showBuffs = true
                self:RefreshStates()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
            elseif data == "openAD" then
                if GUI.SelectTab then GUI.SelectTab("auras_auradesigner") end
            end
        end

        -- Refresh banner content based on current state
        adBanner.refreshContent = function(b, d)
            local _adCfg = DF.GetModeAuraDesigner and DF:GetModeAuraDesigner((d == DF.db.raid) and "raid" or "party")
            local adEnabled = _adCfg and _adCfg.enabled
            if adEnabled and d.showBuffs then
                b:SetHTML(L["Aura Designer is active alongside Buffs."] .. " " ..
                    adLink("openAD", L["Open Aura Designer"]), adOnLink)
            elseif adEnabled and not d.showBuffs then
                b:SetHTML(L["Buffs are disabled. Aura Designer is managing your auras."] .. " " ..
                    adLink("enableBuffs", L["Enable Buffs"]) .. " " ..
                    adLink("openAD", L["Open Aura Designer"]), adOnLink)
            end
        end

        adBanner.hideOn = function(d)
            local _adCfg = DF.GetModeAuraDesigner and DF:GetModeAuraDesigner((d == DF.db.raid) and "raid" or "party")
            return not (_adCfg and _adCfg.enabled)
        end

        Add(adBanner, 32, "both")

        -- Copy button at top right
        Add(CreateCopyButton(self.child, {"buff", "showBuffs"}, L["Buffs"], "auras_buffs"), 25, 2)

        -- ===== DEDUPLICATION =====
        AddSpace(10, "both")
        local dedupGroup = GUI:CreateSettingsGroup(self.child, 280)
        dedupGroup:AddWidget(GUI:CreateHeader(self.child, L["Deduplication"]), 40)
        -- 12.1: dedup semantics changed (Aura Designer auras only; the Defensive Bar's
        -- contents aren't enumerable read-free, and multi-filter duplicates remain a game
        -- limitation) — show a red behaviour-change note instead of the legacy description.
        if DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported() then
            dedupGroup:AddWidget(GUI:CreateLabel(self.child, L["Changed in WoW 12.1: hides auras shown by the Aura Designer from the buff bar. It can no longer hide Defensive Bar duplicates, and a buff matching several buff filters may still show more than once."], 250, GUI.Colors.warning), 60)
        else
            dedupGroup:AddWidget(GUI:CreateLabel(self.child, L["Hide buffs from the buff bar when they are already displayed by the Defensive Bar or Aura Designer."], 250), 45)
        end
        local dedupCb = GUI:CreateCheckbox(self.child, L["Hide Duplicate Buffs"], db, "buffDeduplicateDefensives", function()
            -- Bump the aura layout version so the factory buff row rebuilds with the new
            -- exclusion set (InvalidateAuraLayout -> RefreshFactoryRows -> DriveBuffFactory);
            -- UpdateAllAuras re-scans for the legacy (pre-12.1) dedup path.
            DF:InvalidateAuraLayout()
            DF:UpdateAllAuras()
        end)
        -- On the 12.1 native buff row only the Aura Designer half of this toggle is
        -- expressible (the Defensive Bar's contents aren't enumerable as spell IDs
        -- read-free). The tooltip states the modern behaviour + the known multi-filter
        -- duplicate limitation.
        dedupCb.tooltip = L["Auras shown by the Aura Designer are hidden from the buff bar so they don't appear twice. A buff that matches several buff filters can still show more than once."]
        dedupGroup:AddWidget(dedupCb, 30)
        Add(dedupGroup, nil, 1)

        AddSpace(10, "both")

        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }

        -- ===== LAYOUT SECTION =====
        local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, L["Layout"], true), 36, "both")
        currentSection = layoutSection

        -- Settings Group (col1)
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 260)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        local showBuffsCb = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Buffs"], db, "showBuffs", function()
            self:RefreshStates()
            -- Re-scan auras on visible frames (not just layout): the show/hide gate
            -- lives in the UNIT_AURA-driven UpdateAuras path, so UpdateAllFrames alone
            -- (layout-only) leaves already-shown auras until the next aura event. Use
            -- the same refresh the Max Buffs slider uses.
            DF:RefreshAllVisibleFrames()
        end), 30)
        -- Re-sync checked state when value changes externally (e.g. AD banner click)
        showBuffsCb.refreshContent = function(self)
            local onShow = self:GetScript("OnShow")
            if onShow then onShow(self) end
        end
        local buffMax = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Buffs"], 0, 8, 1, db, "buffMax", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        buffMax.disableOn = function(d) return not d.showBuffs end
        local buffSize = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 10, 40, 1, db, "buffSize", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffSize.disableOn = function(d) return not d.showBuffs end
        local buffScale = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "buffScale", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffScale.disableOn = function(d) return not d.showBuffs end
        local buffAlpha = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.0, 1.0, 0.05, db, "buffAlpha", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffAlpha.disableOn = function(d) return not d.showBuffs end
        AddToSection(settingsGroup, nil, 1)
        
        -- Position Group (col2)
        local positionGroup = GUI:CreateSettingsGroup(self.child, 260)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        local buffAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "buffAnchor", nil), 55)
        buffAnchor.disableOn = function(d) return not d.showBuffs end
        local buffGrowth = positionGroup:AddWidget(GUI:CreateGrowthControl(self.child, db, "buffGrowth", nil), 155)
        buffGrowth.disableOn = function(d) return not d.showBuffs end
        local buffOffsetX = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "buffOffsetX", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffOffsetX.disableOn = function(d) return not d.showBuffs end
        local buffOffsetY = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "buffOffsetY", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffOffsetY.disableOn = function(d) return not d.showBuffs end
        AddToSection(positionGroup, nil, 2)
        
        -- Grid Layout Group (col1)
        local gridGroup = GUI:CreateSettingsGroup(self.child, 260)
        gridGroup:AddWidget(GUI:CreateHeader(self.child, L["Grid Layout"]), 40)
        local buffWrap = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Icons Per Row"], 1, 8, 1, db, "buffWrap", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffWrap.disableOn = function(d) return not d.showBuffs end
        -- 12.1: the native flow layout is row-primary — Vertical orientation renders a single
        -- column, so a per-column wrap count is not expressible there. Blocked only while the
        -- growth is vertical-primary (flipping Orientation un-frosts it live via RefreshStates).
        GUI:BlockControl12_1(buffWrap, "limitation", { id = "buffs:wrapvertical", page = L["Buffs"], when = function(d)
            local g = d.buffGrowth or ""
            -- Vertical-primary AND vertical-centred growth both render a single column.
            return DF:FactoryOwnsBuffRow(d) and (g:sub(1, 2) == "UP" or g:sub(1, 4) == "DOWN"
                or g == "CENTER_LEFT" or g == "CENTER_RIGHT")
        end })
        -- CENTER growth direction: supported on factory rows since the centre-pinned
        -- box in AuraContainer.lua resolveGrowthLayout (the self-sizing container
        -- keeps the row centred) — the old blocked-registry entry is gone.
        local buffPaddingX = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing X"], -5, 10, 1, db, "buffPaddingX", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffPaddingX.disableOn = function(d) return not d.showBuffs end
        local buffPaddingY = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing Y"], -5, 10, 1, db, "buffPaddingY", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffPaddingY.disableOn = function(d) return not d.showBuffs end
        AddToSection(gridGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== APPEARANCE SECTION =====
        local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, L["Appearance"], true), 36, "both")
        currentSection = appearanceSection

        local function MasqueControlsBorders(d)
            -- Masque can't skin the native 12.1 container buttons, so while the
            -- factory owns the row DF's own border renders regardless of the
            -- Integrations toggle — don't hide the border controls for it.
            return DF.Masque and d.masqueBorderControl and not DF:FactoryOwnsBuffRow(d)
        end

        -- Border Group (col1)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 260)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        local buffMasqueNote = borderGroup:AddWidget(GUI:CreateNote(self.child, L["Borders controlled by Masque."] .. " " .. L["See Integrations."], {tone = "caution", width = 230}), 30)
        buffMasqueNote.hideOn = function(d) return not MasqueControlsBorders(d) end
        -- Full border toolkit via the unified helper (Stage 5.5 Phase 2).  No
        -- class/role colour (aura indicators aren't unit-class).  Hidden when
        -- buffs are off or Masque controls the borders.
        local buffBorderW = GUI:CreateBorderControls(borderGroup, db, "buff", {
            parent        = self.child,
            include       = { inset = true, offset = true, blendMode = true,
                              gradient = true, shadow = true, alpha = true,
                              animate = true },
            sizeMin = 0, sizeMax = 8, sizeStep = 1,
            fullUpdate    = function() if DF.UpdateAllFrames then DF:UpdateAllFrames() end end,
            lightUpdate   = function() DF:LightweightUpdateAuraBorder("buff") end,
            lightColors   = function() DF:LightweightUpdateAuraBorder("buff") end,
            refreshStates = function() self:RefreshStates() end,
            hideWhen      = function(d) return not d.showBuffs or MasqueControlsBorders(d) end,
        })
        -- Animations can't run on the 12.1 container buttons (LCG's pooled glow
        -- frames re-SetParent onto the host — forbidden on native AuraButtons), and
        -- the factory strips spec.animation on render. Frost to match; candidate
        -- for deletion in the post-port cleanup sweep.
        GUI:BlockControl12_1(buffBorderW.animationType, "limitation",
            { id = "buffs:borderanimation", page = L["Buffs"], when = function(d) return DF:FactoryOwnsBuffRow(d) end })
        AddToSection(borderGroup, nil, 1)
        
        -- Stack Count Group (col2) — the shared TextStyle control block (font/scale/
        -- outline/shadow/colour/anchor/offsets/justify) + the feature-specific extras.
        local stackCountGroup = GUI:CreateSettingsGroup(self.child, 260)
        stackCountGroup:AddWidget(GUI:CreateHeader(self.child, L["Stack Count"]), 40)
        GUI:CreateTextControls(stackCountGroup, db, "buffStack", {
            parent   = self.child,
            include  = { color = true },
            onChange = function() DF:LightweightUpdateAuraStackText("buff") end,
            onDrag   = function() DF:LightweightUpdateAuraStackText("buff") end,
        })
        local buffStackMin = stackCountGroup:AddWidget(GUI:CreateSlider(self.child, L["Min Stacks to Show"], 1, 10, 1, db, "buffStackMinimum", nil, function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
        -- 12.1: a stacks formatter is FORBIDDEN on container rows (it throws on the secret
        -- combat stack count inside Blizzard's dirty pass and bricks the container — see the
        -- Features/Auras.lua tombstone). Native display = counts > 1, so a custom minimum
        -- is not expressible on the factory row.
        GUI:BlockControl12_1(buffStackMin, "limitation", { id = "buffs:stackminimum", page = L["Buffs"], when = function(d) return DF:FactoryOwnsBuffRow(d) end })
        -- Grey the whole group when Buffs are off, matching Settings/Position/Grid.
        stackCountGroup.disableChildrenOn = function(d) return not d.showBuffs end
        AddToSection(stackCountGroup, nil, 2)
        
        -- Duration Text Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 260)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration"]), 40)
        local durShow = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Duration"], db, "buffShowDuration", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        -- The cooldown swipe (radial sweep) is the OTHER way time-remaining is
        -- shown, so it lives here with Duration Text rather than under Border.
        durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Cooldown Swipe"], db, "buffHideSwipe", nil), 30)
        local durationFormatOptions = { NUMBER = L["Number"], SHORT = L["Short"], FULL = L["Full"] }
        local durFormat = durationGroup:AddWidget(GUI:CreateDropdown(self.child, L["Duration Format"], durationFormatOptions, db, "buffDurationFormat", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
        durFormat.disableOn = function(d) return not d.buffShowDuration end
        -- Shared TextStyle control block (font/scale/outline/shadow/colour/anchor/
        -- offsets/justify). The static colour greys out while Color-by-Time owns it.
        GUI:CreateTextControls(durationGroup, db, "buffDuration", {
            parent     = self.child,
            include    = { color = true },
            colorLabel = L["Duration Color"],
            disableOn  = function(d) return not d.buffShowDuration end,
            colorDisableOn = function(d) return d.buffDurationColorByTime end,
            onChange   = function() DF:LightweightUpdateAuraDurationText("buff") end,
            onDrag     = function() DF:LightweightUpdateAuraDurationText("buff") end,
        })
        local durColor = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Color by Time Remaining"], db, "buffDurationColorByTime", function() self:RefreshStates(); DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
        durColor.disableOn = function(d) return not d.buffShowDuration end
        local durHideAbove = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Above Threshold"], db, "buffDurationHideAboveEnabled", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
        durHideAbove.disableOn = function(d) return not d.buffShowDuration end
        local durHideAboveSlider = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Hide Above (seconds)"], 1, 60, 1, db, "buffDurationHideAboveThreshold", nil, function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
        durHideAboveSlider.disableOn = function(d) return not d.buffShowDuration or not d.buffDurationHideAboveEnabled end
        -- Grey the whole group when Buffs are off (composes with the per-control
        -- buffShowDuration gates), matching Settings/Position/Grid.
        durationGroup.disableChildrenOn = function(d) return not d.showBuffs end
        AddToSection(durationGroup, nil, 2)

        -- Expiring Indicator Group (col1 — placed under Border, matching the
        -- Aura Designer's Border→Expiring ordering)
        local expiringGroup = GUI:CreateSettingsGroup(self.child, 260)
        expiringGroup:AddWidget(GUI:CreateHeader(self.child, L["Expiring Indicator"]), 40)
        -- Unified expiring panel — SAME shared helper + flow as the Aura Designer
        -- (which is the reference design): master enable → Percent/Seconds toggle
        -- threshold → State Overrides → thickness/inset/colour/alpha/animation →
        -- Tint.  Buff-only rows (Show Expiring Border, Color-by-Time, Inset, Tint)
        -- appear via include flags; rows that don't apply simply hide.
        GUI:CreateExpiringControls(expiringGroup, db, {
            parent        = self.child,
            masterLabel   = L["Enable Expiring Indicators"],
            fullUpdate    = function() DF:UpdateAllFrames() end,
            lightColors   = function() DF:LightweightUpdateExpiringBorderColor() end,
            lightGeometry = function() DF:LightweightUpdateAuraBorder("buff") end,
            lightTint     = function() DF:LightweightUpdateExpiringTintColor() end,
            refreshStates = function() self:RefreshStates() end,
            refreshPage   = function() self:Refresh() end,
            keys = {
                master           = "buffExpiringEnabled",
                threshold        = "buffExpiringThreshold",
                thresholdMode    = "buffExpiringThresholdMode",
                borderEnable     = "buffExpiringBorderEnabled",
                colorByTime      = "buffExpiringBorderColorByTime",
                color            = "buffExpiringBorderColor",
                alphaHandleColor = "buffExpiringBorderColor",
                thickness        = "buffExpiringBorderThickness",
                inset            = "buffExpiringBorderInset",
                animPrefix       = "buffExpiringBorderAnimation",
                tintEnable       = "buffExpiringTintEnabled",
                tintColor        = "buffExpiringTintColor",
            },
            include = {
                threshold    = true,
                borderEnable = true,
                colorByTime  = true,
                alpha        = true,
                thickness    = true, thicknessMin = 1, thicknessMax = 5,
                inset        = true,
                animation    = true,
                tint         = true,
            },
        })
        AddToSection(expiringGroup, nil, 1)
        GUI:BlockControl12_1(expiringGroup, "roadmap", { id = "buffs:expiring", page = L["Buffs"], when = function(d) return DF:FactoryOwnsBuffRow(d) end })

        currentSection = nil

        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "display_tooltips", label = L["Buff Tooltips"]},
            {pageId = "general_integrations", label = L["Integrations"]},
            {pageId = "auras_missingbuffs", label = L["Missing Buffs"]},
            {pageId = "auras_defensiveicon", label = L["Defensive Icon"]},
        }), 30, "both")
    end)

    -- Auras > Debuffs (combined Layout + Appearance with collapsible sections)
    local pageDebuffs = CreateSubTab("auras", "auras_debuffs", L["Debuffs"])
    -- 12.1: the debuff row is factory-served (P3). The page blocks only when the
    -- 12.1 aura system is active but the factory does NOT own the row (dev toggle
    -- off) -- the same lift pattern the Defensive Icon page used.
    GUI:BlockPage12_1(pageDebuffs, "roadmap", function(d)
        return GUI:IsAuraFactoryActive() and not DF:FactoryOwnsDebuffRow(d)
    end)
    BuildPage(pageDebuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"debuff", "showDebuffs"}, L["Debuffs"], "auras_debuffs"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }

        -- ===== LAYOUT SECTION =====
        local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, L["Layout"], true), 36, "both")
        currentSection = layoutSection

        -- Settings Group (col1)
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 260)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Debuffs"], db, "showDebuffs", function()
            self:RefreshStates()
            -- See Show Buffs above: re-scan auras on visible frames so a static
            -- debuff hides/shows immediately instead of waiting for the next aura event.
            DF:RefreshAllVisibleFrames()
        end), 30)
        local debuffMax = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Debuffs"], 0, 8, 1, db, "debuffMax", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        debuffMax.disableOn = function(d) return not d.showDebuffs end
        local debuffSize = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 10, 40, 1, db, "debuffSize", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffSize.disableOn = function(d) return not d.showDebuffs end
        local debuffScale = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "debuffScale", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffScale.disableOn = function(d) return not d.showDebuffs end
        local debuffAlpha = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.0, 1.0, 0.05, db, "debuffAlpha", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffAlpha.disableOn = function(d) return not d.showDebuffs end
        AddToSection(settingsGroup, nil, 1)
        
        -- Position Group (col2)
        local positionGroup = GUI:CreateSettingsGroup(self.child, 260)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        local debuffAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "debuffAnchor", nil), 55)
        debuffAnchor.disableOn = function(d) return not d.showDebuffs end
        local debuffGrowth = positionGroup:AddWidget(GUI:CreateGrowthControl(self.child, db, "debuffGrowth", nil), 155)
        debuffGrowth.disableOn = function(d) return not d.showDebuffs end
        local debuffOffsetX = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "debuffOffsetX", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffOffsetX.disableOn = function(d) return not d.showDebuffs end
        local debuffOffsetY = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "debuffOffsetY", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffOffsetY.disableOn = function(d) return not d.showDebuffs end
        AddToSection(positionGroup, nil, 2)
        
        -- Grid Layout Group (col1)
        local gridGroup = GUI:CreateSettingsGroup(self.child, 260)
        gridGroup:AddWidget(GUI:CreateHeader(self.child, L["Grid Layout"]), 40)
        local debuffWrap = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Icons Per Row"], 1, 8, 1, db, "debuffWrap", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffWrap.disableOn = function(d) return not d.showDebuffs end
        local debuffPaddingX = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing X"], -5, 10, 1, db, "debuffPaddingX", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffPaddingX.disableOn = function(d) return not d.showDebuffs end
        local debuffPaddingY = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing Y"], -5, 10, 1, db, "debuffPaddingY", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffPaddingY.disableOn = function(d) return not d.showDebuffs end
        AddToSection(gridGroup, nil, 1)
        
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== APPEARANCE SECTION =====
        local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, L["Appearance"], true), 36, "both")
        currentSection = appearanceSection
        
        local function MasqueControlsBorders(d)
            -- Masque can't skin the native 12.1 container buttons (see the buff page).
            return DF.Masque and d.masqueBorderControl and not DF:FactoryOwnsDebuffRow(d)
        end
        
        local function InvalidateAndUpdate()
            DF.debuffBorderCurve = nil
            DF:UpdateAllFrames()
        end
        
        -- Border Group (col1)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 260)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        local debuffMasqueNote = borderGroup:AddWidget(GUI:CreateNote(self.child, L["Borders controlled by Masque."] .. " " .. L["See Integrations."], {tone = "caution", width = 230}), 30)
        debuffMasqueNote.hideOn = function(d) return not MasqueControlsBorders(d) end
        -- Full border toolkit via the unified helper (Stage 5.5 Phase 2).  When
        -- "Color by Dispel Type" (below) is ON, the border is forced SOLID and
        -- recoloured per dispel type, so Style/Colour/Gradient/Animation here
        -- only take effect when it's OFF (Size/Inset always apply).
        local debuffBorderW = GUI:CreateBorderControls(borderGroup, db, "debuff", {
            parent        = self.child,
            include       = { inset = true, offset = true, blendMode = true,
                              gradient = true, shadow = true, alpha = true,
                              animate = true },
            sizeMin = 0, sizeMax = 8, sizeStep = 1,
            fullUpdate    = function() if DF.UpdateAllFrames then DF:UpdateAllFrames() end end,
            lightUpdate   = function() DF:LightweightUpdateAuraBorder("debuff") end,
            lightColors   = function() DF:LightweightUpdateAuraBorder("debuff") end,
            refreshStates = function() self:RefreshStates() end,
            hideWhen      = function(d) return not d.showDebuffs or MasqueControlsBorders(d) end,
        })
        -- Animations can't run on the 12.1 container buttons (see the buff page);
        -- the factory strips spec.animation on render. Deletion candidate post-port.
        GUI:BlockControl12_1(debuffBorderW.animationType, "limitation",
            { id = "debuffs:borderanimation", page = L["Debuffs"], when = function(d) return DF:FactoryOwnsDebuffRow(d) end })
        local colorByType = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Color by Dispel Type"], db, "debuffBorderColorByType", InvalidateAndUpdate), 30)
        colorByType.disableOn = function(d) return not d.debuffShowBorder or MasqueControlsBorders(d) end
        colorByType.hideOn = function(d) return MasqueControlsBorders(d) end
        -- 12.1 rows: the native dispel ring's inset (+ inward / - outward halo; the
        -- ring geometry is ours even though Blizzard tints it). Live via restyle.
        local dispelInset = borderGroup:AddWidget(GUI:CreateSlider(self.child, L["Dispel Border Inset"], -8, 8, 1, db, "debuffDispelBorderInset", nil, function() DF:LightweightUpdateAuraBorder("debuff") end, true), 55)
        dispelInset.disableOn = function(d) return not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        dispelInset.hideOn = function(d) return MasqueControlsBorders(d) or not DF:FactoryOwnsDebuffRow(d) end
        AddToSection(borderGroup, nil, 1)
        
        -- Dispel Colors Group (col2)
        local colorsGroup = GUI:CreateSettingsGroup(self.child, 260)
        colorsGroup:AddWidget(GUI:CreateHeader(self.child, L["Dispel Type Colors"]), 40)
        local magicColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Magic"], db, "debuffBorderColorMagic", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        magicColor.disableOn = function(d) return not d.debuffShowBorder or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local curseColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Curse"], db, "debuffBorderColorCurse", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        curseColor.disableOn = function(d) return not d.debuffShowBorder or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local diseaseColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Disease"], db, "debuffBorderColorDisease", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        diseaseColor.disableOn = function(d) return not d.debuffShowBorder or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local poisonColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Poison"], db, "debuffBorderColorPoison", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        poisonColor.disableOn = function(d) return not d.debuffShowBorder or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local bleedColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Bleed / Enrage"], db, "debuffBorderColorBleed", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        bleedColor.disableOn = function(d) return not d.debuffShowBorder or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local noneColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, L["None / Physical"], db, "debuffBorderColorNone", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        noneColor.disableOn = function(d) return not d.debuffShowBorder or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        colorsGroup.hideOn = function(d) return MasqueControlsBorders(d) end
        -- 12.1: the native dispel border is coloured PRIVATE-side from Blizzard's
        -- standard dispel palette (the aura's dispel type is secret) -- custom
        -- per-type colours are not expressible on the factory row.
        GUI:BlockControl12_1(colorsGroup, "limitation",
            { id = "debuffs:dispelcolors", page = L["Debuffs"], when = function(d) return DF:FactoryOwnsDebuffRow(d) end })
        AddToSection(colorsGroup, nil, 2)
        
        -- Stack Count Group (col1)
        local stackCountGroup = GUI:CreateSettingsGroup(self.child, 260)
        stackCountGroup:AddWidget(GUI:CreateHeader(self.child, L["Stack Count"]), 40)
        stackCountGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "debuffStackFont", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "debuffStackScale", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "debuffStackOutline", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "debuffStackOutline", function() DF:LightweightUpdateAuraStackText("debuff") end), 30)
        stackCountGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "debuffStackAnchor", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "debuffStackX", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "debuffStackY", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "debuffStackColor", false, function() DF:LightweightUpdateAuraStackText("debuff") end, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 30)
        local debuffStackMin = stackCountGroup:AddWidget(GUI:CreateSlider(self.child, L["Min Stacks to Show"], 1, 10, 1, db, "debuffStackMinimum", nil), 55)
        GUI:BlockControl12_1(debuffStackMin, "limitation", { id = "debuffs:stackminimum", page = L["Debuffs"], when = function(d) return DF:FactoryOwnsDebuffRow(d) end })
        -- Grey the whole group when Debuffs are off, matching Settings/Position/Grid.
        stackCountGroup.disableChildrenOn = function(d) return not d.showDebuffs end
        AddToSection(stackCountGroup, nil, 1)
        
        -- Duration Text Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 260)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration"]), 40)
        local durShow = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Duration"], db, "debuffShowDuration", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        -- Cooldown swipe (radial time-remaining) lives with Duration Text, not Border.
        durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Cooldown Swipe"], db, "debuffHideSwipe", nil), 30)
        local debuffDurationFormatOptions = { NUMBER = L["Number"], SHORT = L["Short"], FULL = L["Full"] }
        local durFormat = durationGroup:AddWidget(GUI:CreateDropdown(self.child, L["Duration Format"], debuffDurationFormatOptions, db, "debuffDurationFormat", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
        durFormat.disableOn = function(d) return not d.debuffShowDuration end
        local durFont = durationGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "debuffDurationFont", nil), 55)
        durFont.disableOn = function(d) return not d.debuffShowDuration end
        local durScale = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "debuffDurationScale", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
        durScale.disableOn = function(d) return not d.debuffShowDuration end
        local durOutline = durationGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "debuffDurationOutline", function() DF:LightweightUpdateAuraDurationText("debuff") end), 55)
        durOutline.disableOn = function(d) return not d.debuffShowDuration end
        local durShadow = durationGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "debuffDurationOutline", function() DF:LightweightUpdateAuraDurationText("debuff") end), 30)
        durShadow.disableOn = function(d) return not d.debuffShowDuration end
        local durAnchor = durationGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "debuffDurationAnchor", function() DF:LightweightUpdateAuraDurationText("debuff") end), 55)
        durAnchor.disableOn = function(d) return not d.debuffShowDuration end
        local durX = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "debuffDurationX", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
        durX.disableOn = function(d) return not d.debuffShowDuration end
        local durY = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "debuffDurationY", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
        durY.disableOn = function(d) return not d.debuffShowDuration end
        local durColorPick = durationGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Duration Color"], db, "debuffDurationColor", false, function() DF:LightweightUpdateAuraDurationText("debuff") end, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 30)
        durColorPick.disableOn = function(d) return not d.debuffShowDuration or d.debuffDurationColorByTime end
        local durColor = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Color by Time Remaining"], db, "debuffDurationColorByTime", function() self:RefreshStates(); DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
        durColor.disableOn = function(d) return not d.debuffShowDuration end
        local durHideAbove = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Above Threshold"], db, "debuffDurationHideAboveEnabled", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
        durHideAbove.disableOn = function(d) return not d.debuffShowDuration end
        local durHideAboveSlider = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Hide Above (seconds)"], 1, 60, 1, db, "debuffDurationHideAboveThreshold", nil, function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
        durHideAboveSlider.disableOn = function(d) return not d.debuffShowDuration or not d.debuffDurationHideAboveEnabled end
        -- Grey the whole group when Debuffs are off (composes with the per-control
        -- debuffShowDuration gates), matching Settings/Position/Grid.
        durationGroup.disableChildrenOn = function(d) return not d.showDebuffs end
        AddToSection(durationGroup, nil, 2)

        currentSection = nil

        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "display_tooltips", label = L["Debuff Tooltips"]},
            {pageId = "general_integrations", label = L["Integrations"]},
            {pageId = "auras_dispel", label = L["Dispel Overlay"]},
        }), 30, "both")
    end)
    
    
    -- Auras > Missing Buffs
    local pageMissingBuffs = CreateSubTab("auras", "auras_missingbuffs", L["Missing Buffs"])
    -- 12.1: missing buffs are factory-served (read-free layout-push widget). The page
    -- blocks only when the 12.1 aura system is active but the factory does NOT own the
    -- feature (dev toggle off) -- the same lift pattern the Debuffs page used.
    GUI:BlockPage12_1(pageMissingBuffs, "roadmap", function(d)
        return GUI:IsAuraFactoryActive() and not DF:FactoryOwnsMissingBuff(d)
    end)
    BuildPage(pageMissingBuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"missingBuff"}, L["Missing Buffs"], "auras_missingbuffs"), 25, 2)
        
        AddSpace(10, "both")
        
        -- Dependent controls GREY OUT (disabled-in-place) when the feature is off.
        local function HideMissingBuffOptions(d)
            return not d.missingBuffIconEnabled
        end

        -- Manual-mode buffs HIDE when auto-detect is on (variant gate); they GREY
        -- via the group's disableChildrenOn when the feature itself is disabled.
        local function HideManualBuffVariant(d)
            return d.missingBuffClassDetection
        end

        -- 12.1 factory path: settings apply through the version-gated drive, so a
        -- change must bump the aura layout version (InvalidateAuraLayout re-drives
        -- every factory widget, missing-buff strip included). Legacy path unchanged.
        local function refreshMissing()
            if DF.FactoryOwnsMissingBuff and DF:FactoryOwnsMissingBuff(db) then
                DF:InvalidateAuraLayout()
            end
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end

        local anchorOptions = {
            ["TOPLEFT"]= L["Top Left"], ["TOP"]= L["Top"], ["TOPRIGHT"]= L["Top Right"],
            ["LEFT"]= L["Left"], ["CENTER"]= L["Center"], ["RIGHT"]= L["Right"],
            ["BOTTOMLEFT"]= L["Bottom Left"], ["BOTTOM"]= L["Bottom"], ["BOTTOMRIGHT"]= L["Bottom Right"],
        }
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Shows icon when party members are missing raid buffs."], 250), 30)
        -- 12.1 (factory path): the read-free widget works in combat + Mythic+ and
        -- shows EVERY tracked-and-missing buff (the legacy "first missing only"
        -- priority pick needed a cross-aura read). Legacy path keeps the caveat.
        local mbOwns = DF.FactoryOwnsMissingBuff and DF:FactoryOwnsMissingBuff(db)
        local mPlusWarn = GUI:CreateInfoBanner(self.child, { tone = mbOwns and "info" or "caution" })
        mPlusWarn:SetText(mbOwns
            and L["Updates instantly, including in combat and Mythic+. Each tracked buff that is missing shows its own icon."]
            or L["Does NOT work in Mythic+ keystones. In combat, results may be slightly delayed."])
        settingsGroup:AddWidget(mPlusWarn, 60)
        local missingBuffEnable = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Missing Buff Icon"], db, "missingBuffIconEnabled", function()
            self:RefreshStates()
            refreshMissing()
        end), 30)
        missingBuffEnable.keepEnabled = true
        settingsGroup.disableChildrenOn = HideMissingBuffOptions
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Auto-detect (your class's buff)"], db, "missingBuffClassDetection", function()
            self:RefreshStates()
            refreshMissing()
        end), 30)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Raid Buffs from Buff Bar"], db, "missingBuffHideFromBar", function()
            -- Factory: the exclusion is a structural candidate-filter on the BUFF row —
            -- refreshMissing's InvalidateAuraLayout re-drives it (sig change -> Rebuild).
            refreshMissing()
            DF:UpdateAllAuras()
        end), 30)
        local mbDebug = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Debug Mode (print to chat)"], db, "missingBuffIconDebug", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        -- The debug trace narrates the legacy UnitHasBuff scan, which never runs on
        -- the read-free 12.1 widget (there is nothing to print — presence is never
        -- known to Lua). Candidate for deletion in the post-port cleanup sweep.
        GUI:BlockControl12_1(mbDebug, "limitation",
            { id = "missingbuffs:debug", page = L["Missing Buffs"], when = function(d) return DF:FactoryOwnsMissingBuff(d) end })
        Add(settingsGroup, nil, 1)
        
        -- ===== BUFFS TO CHECK GROUP (Column 2) =====
        local buffsGroup = GUI:CreateSettingsGroup(self.child, 280)
        buffsGroup:AddWidget(GUI:CreateHeader(self.child, L["Buffs to Check (Manual Mode)"]), 40)
        buffsGroup:AddWidget(GUI:CreateLabel(self.child, L["When auto-detect is OFF, select which raid buffs to monitor manually."], 250), 35)
        buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Arcane Intellect (Mage)"], db, "missingBuffCheckIntellect", function()
            refreshMissing()
        end), 30)
        buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Power Word: Fortitude (Priest)"], db, "missingBuffCheckStamina", function()
            refreshMissing()
        end), 30)
        buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Battle Shout (Warrior)"], db, "missingBuffCheckAttackPower", function()
            refreshMissing()
        end), 30)
        buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Mark of the Wild (Druid)"], db, "missingBuffCheckVersatility", function()
            refreshMissing()
        end), 30)
        buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Skyfury (Shaman)"], db, "missingBuffCheckSkyfury", function()
            refreshMissing()
        end), 30)
        buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Blessing of the Bronze (Evoker)"], db, "missingBuffCheckBronze", function()
            refreshMissing()
        end), 30)
        buffsGroup.hideOn = HideManualBuffVariant
        buffsGroup.disableChildrenOn = HideMissingBuffOptions
        Add(buffsGroup, nil, 2)
        
        -- ===== APPEARANCE GROUP (Column 1) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        appearanceGroup.disableChildrenOn = HideMissingBuffOptions
        appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 12, 48, 1, db, "missingBuffIconSize", function()
            refreshMissing()
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 3.0, 0.1, db, "missingBuffIconScale", function()
            refreshMissing()
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "missingBuffIconFrameLevel", function()
            refreshMissing()
        end, function() DF:LightweightUpdateFrameLevel("missingBuff") end, true), 55)
        Add(appearanceGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        positionGroup.disableChildrenOn = HideMissingBuffOptions
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "missingBuffIconAnchor", function()
            refreshMissing()
        end), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "missingBuffIconX", function()
            refreshMissing()
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "missingBuffIconY", function()
            refreshMissing()
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== BORDER GROUP (Column 1) =====
        -- Stage 4.1: hand-rolled border block replaced by the unified helper.
        -- include set tailored for a "needs attention" alert: alpha / inset /
        -- offset / blendMode / gradient / shadow / animate (matches the
        -- Defensive Icon — Border Offset nudges the band relative to the icon).
        -- Class/Role colour offered too: the missing-buff icon sits on a unit
        -- frame, so its border can communicate WHOSE buff is missing at a glance.
        -- Skipped: colour-by-time / colour-by-type (no aura-state context here).
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        local mbBorderW = GUI:CreateBorderControls(borderGroup, db, "missingBuffIcon", {
            parent       = self.child,
            include      = { alpha = true, inset = true, offset = true, blendMode = true,
                             gradient = true, shadow = true, animate = true,
                             classColor = true, roleColor = true },
            -- Only the DF-owned (secretRect-driven) animations work on 12.1 buttons;
            -- the LCG glows SetParent onto the native button (forbidden). Hide them.
            animExcludeTypes = { PULSATE = true, CHASE = true, FLASH = true, PROC = true },
            fullUpdate   = function() refreshMissing() end,
            lightUpdate  = function() DF:LightweightUpdateMissingBuff() end,
            lightColors  = function() DF:LightweightUpdateMissingBuffBorderColor() end,
            refreshStates = function() self:RefreshStates() end,
            hideWhen     = function(d) return not d.missingBuffIconEnabled end,
            sizeMin = 0, sizeMax = 6, sizeStep = 1,  -- 0 = animation-only (no solid edge)
        })
        borderGroup.disableChildrenOn = HideMissingBuffOptions
        Add(borderGroup, nil, 1)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buffs"]},
        }), 30, "both")
    end)
    
    -- Auras > Defensive Icon
    local pageDefensiveIcon = CreateSubTab("auras", "auras_defensiveicon", L["Defensive Icon"])
    -- 12.1: defensive icons now render through DF.AuraContainer (native BIG_DEFENSIVE /
    -- EXTERNAL_DEFENSIVE filters); the legacy path stays as a secret-hardened fallback, so
    -- the page is usable — no whole-page banner, and nothing is blocked (frame level IS
    -- honored, via the container's frameLevelOffset). Known gaps the factory doesn't
    -- reproduce yet (not cleanly addressable, left as-is): border animation (inlined in the
    -- shared border helper) and CENTER growth (a dropdown option that falls back to RIGHT).
    BuildPage(pageDefensiveIcon, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"defensiveIcon"}, L["Defensive Icon"], "auras_defensiveicon"), 25, 2)
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        
        -- Dependent controls GREY OUT (disabled-in-place) when the feature is off.
        local function HideDefensiveIconOptions(d)
            return not d.defensiveIconEnabled
        end

        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Shows an icon when party members have a defensive cooldown active (Pain Suppression, Ironbark, etc.)."], 250), 45)
        local defensiveEnable = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Defensive Icon"], db, "defensiveIconEnabled", function()
            self:RefreshStates()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        defensiveEnable.keepEnabled = true
        settingsGroup.disableChildrenOn = HideDefensiveIconOptions

        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Cooldown Swipe"], db, "defensiveIconHideSwipe", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        Add(settingsGroup, nil, 1)
        
        -- ===== APPEARANCE GROUP (Column 2) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        appearanceGroup.disableChildrenOn = HideDefensiveIconOptions

        appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 12, 48, 1, db, "defensiveIconSize", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)

        appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 4.0, 0.1, db, "defensiveIconScale", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)

        appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "defensiveIconFrameLevel", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateFrameLevel("defensive") end, true), 55)

        appearanceGroup:AddWidget(GUI:CreateLabel(self.child, L["0=Auto, Higher=On top of more elements"], 230), 25)
        Add(appearanceGroup, nil, 2)
        
        -- ===== POSITION GROUP (Column 1) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        positionGroup.disableChildrenOn = HideDefensiveIconOptions

        positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "defensiveIconAnchor", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 55)

        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "defensiveIconX", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)

        positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "defensiveIconY", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        Add(positionGroup, nil, 1)
        
        -- ===== BORDER GROUP (Column 2) =====
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)

        -- Canonical border controls via the unified helper. include opts in
        -- inset / offset / blendMode / gradient / shadow on top of the
        -- always-present Show / Style / Texture / Size / Colour. Inset moves
        -- the border edges inward (positive) or outward (negative) relative
        -- to the icon's bounds — independent of borderSize (thickness) and
        -- independent of the artwork's own inset.
        local defBorderW = GUI:CreateBorderControls(borderGroup, db, "defensiveIcon", {
            parent       = self.child,
            -- Class/Role colour makes sense here: at a glance, the border
            -- communicates WHO is using the defensive cooldown (their class
            -- or role) without the user having to read the icon. Animation
            -- is useful as a "needs attention" alert when a high-priority
            -- defensive fires.
            include      = { inset = true, offset = true, blendMode = true,
                             gradient = true, shadow = true, alpha = true,
                             classColor = true, roleColor = true,
                             animate = true },
            -- DF-owned animations only (see the missing-buff note); LCG glows are
            -- forbidden on native aura buttons.
            animExcludeTypes = { PULSATE = true, CHASE = true, FLASH = true, PROC = true },
            fullUpdate   = function() if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end end,
            lightUpdate  = function() DF:LightweightUpdateDefensiveIcons() end,
            lightColors  = function() DF:LightweightUpdateDefensiveIconColors() end,
            refreshStates = function() self:RefreshStates() end,
            hideWhen     = function(d) return not d.defensiveIconEnabled end,
        })
        borderGroup.disableChildrenOn = HideDefensiveIconOptions
        Add(borderGroup, nil, 2)
        
        -- ===== DURATION GROUP (Column 1) =====
        local durationGroup = GUI:CreateSettingsGroup(self.child, 280)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Text"]), 40)
        
        durationGroup.disableChildrenOn = HideDefensiveIconOptions
        durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Duration"], db, "defensiveIconShowDuration", function()
            self:RefreshStates()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)

        -- Sub-controls HIDE when Show Duration is off (variant gate); they GREY
        -- via the group's disableChildrenOn when the feature itself is disabled.
        local function HideDefensiveDurationOptions(d)
            return not d.defensiveIconShowDuration
        end

        -- Shared TextStyle control block (font/scale/outline/shadow/colour/anchor/
        -- offsets/justify). The offsets/anchor honor the existing defensiveIconDurationX/Y
        -- keys (previously config-only); the static colour greys while Color-by-Time owns it.
        GUI:CreateTextControls(durationGroup, db, "defensiveIconDuration", {
            parent     = self.child,
            include    = { color = true },
            colorLabel = L["Duration Color"],
            hideOn     = HideDefensiveDurationOptions,
            colorDisableOn = function(d) return d.defensiveIconDurationColorByTime end,
            onChange   = function() if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end end,
            onDrag     = function() DF:LightweightUpdateDefensiveIcons() end,
        })

        local diDurColorByTime = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Color by Time Remaining"], db, "defensiveIconDurationColorByTime", function()
            self:RefreshStates()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        diDurColorByTime.hideOn = HideDefensiveDurationOptions

        Add(durationGroup, nil, 1)

        -- (The old "Duration Position" group is gone: CreateTextControls above already
        -- renders Anchor + Offset X/Y on the same defensiveIconDurationX/Y keys — the
        -- separate group was a duplicate left behind by the TextStyle conversion.)

        -- ===== LAYOUT GROUP (Column 1) =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout"]), 40)
        layoutGroup:AddWidget(GUI:CreateLabel(self.child, L["Controls how multiple defensive icons are arranged."], 250), 45)
        layoutGroup.disableChildrenOn = HideDefensiveIconOptions

        layoutGroup:AddWidget(GUI:CreateGrowthControl(self.child, db, "defensiveBarGrowth", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 155)
        layoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Icons"], 1, 5, 1, db, "defensiveBarMax", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, nil, true), 55)

        local defWrap = layoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Icons Per Row"], 1, 5, 1, db, "defensiveBarWrap", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, nil, true), 55)
        -- 12.1: row-primary flow — vertical orientation = single column, wrap count not
        -- expressible (mirrors the Buffs-page block).
        GUI:BlockControl12_1(defWrap, "limitation", { id = "defensive:wrapvertical", page = L["Defensive Icon"], when = function(d)
            local g = d.defensiveBarGrowth or ""
            -- Vertical-primary AND vertical-centred growth both render a single column.
            return DF:FactoryOwnsDefensiveRow(d) and (g:sub(1, 2) == "UP" or g:sub(1, 4) == "DOWN"
                or g == "CENTER_LEFT" or g == "CENTER_RIGHT")
        end })

        layoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing"], -10, 10, 1, db, "defensiveBarSpacing", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)

        Add(layoutGroup, nil, 1)

        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buffs"]},
            {pageId = "auras_debuffs", label = L["Debuffs"]},
            {pageId = "auras_filters", label = L["Aura Filters"]},
            {pageId = "general_integrations", label = L["Integrations"]},
        }), 30, "both")
    end)
    
    -- ========================================
    -- CATEGORY: Indicators
    -- ========================================
    CreateCategory("indicators", L["Indicators"])
    
    -- Indicators > Targeted Spells (moved from Auras)
    local pageTargetedSpells = CreateSubTab("indicators", "indicators_targetedspells", L["Targeted Spells"])
    BuildPage(pageTargetedSpells, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"targetedSpell"}, L["Targeted Spells"], "indicators_targetedspells"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        local growthOptions = { UP= L["Up"], DOWN= L["Down"], LEFT= L["Left"], RIGHT= L["Right"], CENTER_H= L["Center (Horizontal)"], CENTER_V= L["Center (Vertical)"] }
        
        local function HideTargetedSpellOptions(d) return not d.targetedSpellEnabled end
        local function HideTargetedDurationOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellShowDuration end
        
        local function TargetedSpellLightweightUpdate()
            if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestTargetedSpell then DF:UpdateAllTestTargetedSpell() end
        end
        
        local function FullUpdate()
            if DF.UpdateAllTargetedSpellLayouts then DF:UpdateAllTargetedSpellLayouts() end
            TargetedSpellLightweightUpdate()
        end

        -- ===== DISCLAIMER BANNER (full width) =====
        local tsDisclaimerBanner = GUI:CreateInfoBanner(self.child, {
            tone = "caution",
            text = L["Targeted Spells guesses who an enemy is targeting from their class, role, race, and sex. Members who share all four can't be told apart and won't show an icon."],
        })
        Add(tsDisclaimerBanner, tsDisclaimerBanner.layoutHeight, "both")

        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Shows an icon when an enemy is casting a spell targeting a party/raid member."], 250), 35)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Targeted Spells"], db, "targetedSpellEnabled", function()
            self:RefreshStates()
            if DF.ToggleTargetedSpells then DF:ToggleTargetedSpells(db.targetedSpellEnabled) end
        end), 30)
        local tsWarnDup = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Warn About Untrackable Duplicates"], db, "targetedSpellWarnDuplicates", nil), 30)
        tsWarnDup.disableOn = HideTargetedSpellOptions
        local tsUntrackableLabel = settingsGroup:AddWidget(GUI:CreateLabel(self.child, "", 250), 30)
        function DF:RefreshTargetedSpellUntrackable()
            if not tsUntrackableLabel then return end
            local names = DF.TargetedSpells_GetUntrackableNames and DF:TargetedSpells_GetUntrackableNames() or {}
            if #names >= 2 then
                tsUntrackableLabel:SetText(string.format(L["Currently can't track: %s"], table.concat(names, ", ")))
            else
                tsUntrackableLabel:SetText("")
            end
        end
        DF:RefreshTargetedSpellUntrackable()
        local tsImportantOnly = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Important Spells Only"], db, "targetedSpellImportantOnly", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsImportantOnly.disableOn = HideTargetedSpellOptions
        local tsNameplateOffscreen = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Offscreen Nameplates"], db, "targetedSpellNameplateOffscreen", function()
            if DF.SetNameplateOffscreen then DF:SetNameplateOffscreen(db.targetedSpellNameplateOffscreen) end
            FullUpdate()
        end), 30)
        tsNameplateOffscreen.disableOn = HideTargetedSpellOptions
        settingsGroup:AddWidget(GUI:CreateButton(self.child, L["Run Setup Wizard"], 160, 24, function()
            if DF.ShowTargetedSpellSetupWizard then DF:ShowTargetedSpellSetupWizard() end
        end), 34)
        Add(settingsGroup, nil, 1)
        
        -- ===== CONTENT TYPES GROUP (Column 2) =====
        local contentGroup = GUI:CreateSettingsGroup(self.child, 280)
        contentGroup:AddWidget(GUI:CreateHeader(self.child, L["Content Types"]), 40)
        contentGroup:AddWidget(GUI:CreateLabel(self.child, L["Show in content types:"], 250), 25)
        local tsOpenWorld = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Open World"], db, "targetedSpellInOpenWorld", nil), 25)
        tsOpenWorld.disableOn = HideTargetedSpellOptions
        local tsDungeons = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Dungeons"], db, "targetedSpellInDungeons", nil), 25)
        tsDungeons.disableOn = HideTargetedSpellOptions
        tsDungeons.hideOn = function() return GUI.SelectedMode == "raid" end
        local tsArena = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Arena"], db, "targetedSpellInArena", nil), 25)
        tsArena.disableOn = HideTargetedSpellOptions
        tsArena.hideOn = function() return GUI.SelectedMode == "raid" end
        local tsRaids = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Raids"], db, "targetedSpellInRaids", nil), 25)
        tsRaids.disableOn = HideTargetedSpellOptions
        tsRaids.hideOn = function() return GUI.SelectedMode ~= "raid" end
        local tsBattlegrounds = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Battlegrounds"], db, "targetedSpellInBattlegrounds", nil), 25)
        tsBattlegrounds.disableOn = HideTargetedSpellOptions
        tsBattlegrounds.hideOn = function() return GUI.SelectedMode ~= "raid" end
        contentGroup.hideOn = HideTargetedSpellOptions
        Add(contentGroup, nil, 2)
        
        -- Cast History button
        local historyBtn = GUI:CreateButton(self.child, L["Open Cast History"], 140, 24, function()
            if DF.ShowCastHistoryUI then DF:ShowCastHistoryUI() end
        end)
        Add(historyBtn, 30, 1)
        
        AddSpace(10, "both")
        
        -- ===== LAYOUT SECTION =====
        local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, L["Layout"], true), 36, "both")
        currentSection = layoutSection
        
        -- Position Group (col1)
        local positionGroup = GUI:CreateSettingsGroup(self.child, 260)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        local tsAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "targetedSpellAnchor", FullUpdate), 55)
        tsAnchor.disableOn = HideTargetedSpellOptions
        local tsX = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "targetedSpellX", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsX.disableOn = HideTargetedSpellOptions
        local tsY = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "targetedSpellY", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsY.disableOn = HideTargetedSpellOptions
        local tsGrowth = positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growthOptions, db, "targetedSpellGrowth", FullUpdate), 55)
        tsGrowth.disableOn = HideTargetedSpellOptions
        AddToSection(positionGroup, nil, 1)
        
        -- Size Group (col2)
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 260)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Size"]), 40)
        local tsIconSize = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 12, 48, 1, db, "targetedSpellSize", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsIconSize.disableOn = HideTargetedSpellOptions
        local tsScale = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 4.0, 0.1, db, "targetedSpellScale", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsScale.disableOn = HideTargetedSpellOptions
        local tsAlpha = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.0, 1.0, 0.05, db, "targetedSpellAlpha", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsAlpha.disableOn = HideTargetedSpellOptions
        local tsSpacing = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing"], 0, 10, 1, db, "targetedSpellSpacing", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsSpacing.disableOn = HideTargetedSpellOptions
        local tsMaxIcons = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Icons"], 1, 10, 1, db, "targetedSpellMaxIcons", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsMaxIcons.disableOn = HideTargetedSpellOptions
        local tsLevel = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "targetedSpellFrameLevel", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsLevel.disableOn = HideTargetedSpellOptions
        AddToSection(sizeGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== APPEARANCE SECTION =====
        local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, L["Appearance"], true), 36, "both")
        currentSection = appearanceSection
        
        -- Border Group (col1)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 260)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        -- Full DF.Border toolkit (matches Personal Targeted Spell): Show Border,
        -- Size, Style/Gradient, Colour, Alpha, Inset, Blend Mode, Shadow, Animate.
        -- BuildSpec in ApplyIconSettings already reads every targetedSpell* border
        -- key, so these controls light up the whole engine.
        GUI:CreateBorderControls(borderGroup, db, "targetedSpell", {
            parent        = self.child,
            include       = { alpha = true, inset = true, blendMode = true,
                              gradient = true, shadow = true, animate = true },
            fullUpdate    = FullUpdate,
            lightUpdate   = TargetedSpellLightweightUpdate,
            lightColors   = FullUpdate,
            refreshStates = function() self:RefreshStates() end,
            hideWhen      = HideTargetedSpellOptions,
            sizeMin = 0, sizeMax = 8, sizeStep = 1,
        })
        AddToSection(borderGroup, nil, 1)
        
        -- Duration Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 260)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Text"]), 40)
        local showDur = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Duration"], db, "targetedSpellShowDuration", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        showDur.disableOn = HideTargetedSpellOptions
        -- The cooldown swipe is the radial cooldown sweep on the icon (independent
        -- of the numeric duration text), so it's gated only on the feature itself.
        local hideSwipe = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Cooldown Swipe"], db, "targetedSpellHideSwipe", FullUpdate), 30)
        hideSwipe.disableOn = HideTargetedSpellOptions
        local tsDurFont = durationGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "targetedSpellDurationFont", FullUpdate), 55)
        tsDurFont.disableOn = HideTargetedDurationOptions
        local tsDurScale = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "targetedSpellDurationScale", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsDurScale.disableOn = HideTargetedDurationOptions
        local tsDurOutline = durationGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "targetedSpellDurationOutline", FullUpdate), 55)
        tsDurOutline.disableOn = HideTargetedDurationOptions
        local tsDurShadow = durationGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "targetedSpellDurationOutline", FullUpdate), 30)
        tsDurShadow.disableOn = HideTargetedDurationOptions
        local tsDurX = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -20, 20, 1, db, "targetedSpellDurationX", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsDurX.disableOn = HideTargetedDurationOptions
        local tsDurY = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -20, 20, 1, db, "targetedSpellDurationY", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsDurY.disableOn = HideTargetedDurationOptions
        local tsDurColor = durationGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "targetedSpellDurationColor", false, FullUpdate), 35)
        tsDurColor.disableOn = HideTargetedDurationOptions
        AddToSection(durationGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== IMPORTANT SPELLS SECTION =====
        local importantSection = Add(GUI:CreateCollapsibleSection(self.child, L["Important Spells"], true), 36, "both")
        currentSection = importantSection
        
        local function HideHighlightOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellHighlightImportant end

        local highlightGroup = GUI:CreateSettingsGroup(self.child, 260)
        highlightGroup:AddWidget(GUI:CreateHeader(self.child, L["Highlight Settings"]), 40)
        local tsHighlightImportant = highlightGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Highlight Important Spells"], db, "targetedSpellHighlightImportant", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsHighlightImportant.disableOn = HideTargetedSpellOptions
        -- Important Spell Border: the highlight on its own DF.Border (full toolkit),
        -- gated by the Highlight Important Spells toggle above.
        GUI:CreateBorderControls(highlightGroup, db, "targetedSpellImportant", {
            parent        = self.child,
            noShowToggle  = true,  -- the Highlight Important Spells checkbox is the gate
            include       = { alpha = true, inset = true, blendMode = true,
                              gradient = true, shadow = true, animate = true },
            fullUpdate    = FullUpdate,
            lightUpdate   = TargetedSpellLightweightUpdate,
            lightColors   = FullUpdate,
            refreshStates = function() self:RefreshStates() end,
            hideWhen      = HideHighlightOptions,
            sizeMin = 0, sizeMax = 8, sizeStep = 1,
        })
        AddToSection(highlightGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== INTERRUPTED VISUAL SECTION =====
        local interruptedSection = Add(GUI:CreateCollapsibleSection(self.child, L["Interrupted Visual"], true), 36, "both")
        currentSection = interruptedSection
        
        local function HideInterruptedOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellShowInterrupted end
        local function HideXOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellShowInterrupted or not d.targetedSpellInterruptedShowX end
        
        local interruptGroup = GUI:CreateSettingsGroup(self.child, 260)
        interruptGroup:AddWidget(GUI:CreateHeader(self.child, L["Interrupt Settings"]), 40)
        local tsShowInterrupted = interruptGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Interrupted Visual"], db, "targetedSpellShowInterrupted", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsShowInterrupted.disableOn = HideTargetedSpellOptions
        local tsInterruptedDuration = interruptGroup:AddWidget(GUI:CreateSlider(self.child, L["Duration"], 0.1, 2.0, 0.1, db, "targetedSpellInterruptedDuration", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsInterruptedDuration.disableOn = HideInterruptedOptions
        local tsInterruptedTintColor = interruptGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Tint Color"], db, "targetedSpellInterruptedTintColor", false, FullUpdate), 35)
        tsInterruptedTintColor.disableOn = HideInterruptedOptions
        local tsInterruptedTintAlpha = interruptGroup:AddWidget(GUI:CreateSlider(self.child, L["Tint Opacity"], 0, 1, 0.1, db, "targetedSpellInterruptedTintAlpha", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsInterruptedTintAlpha.disableOn = HideInterruptedOptions
        AddToSection(interruptGroup, nil, 1)
        
        local xMarkGroup = GUI:CreateSettingsGroup(self.child, 260)
        xMarkGroup:AddWidget(GUI:CreateHeader(self.child, L["X Mark"]), 40)
        local tsInterruptedShowX = xMarkGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show X Mark"], db, "targetedSpellInterruptedShowX", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsInterruptedShowX.disableOn = HideInterruptedOptions
        local tsInterruptedXColor = xMarkGroup:AddWidget(GUI:CreateColorPicker(self.child, L["X Color"], db, "targetedSpellInterruptedXColor", false, FullUpdate), 35)
        tsInterruptedXColor.disableOn = HideXOptions
        local tsInterruptedXSize = xMarkGroup:AddWidget(GUI:CreateSlider(self.child, L["X Size"], 8, 32, 1, db, "targetedSpellInterruptedXSize", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsInterruptedXSize.disableOn = HideXOptions
        xMarkGroup.hideOn = HideInterruptedOptions
        AddToSection(xMarkGroup, nil, 2)
        
        currentSection = nil
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buffs"]},
            {pageId = "auras_debuffs", label = L["Debuffs"]},
            {pageId = "general_integrations", label = L["Integrations"]},
            {pageId = "indicators_personal_targeted", label = L["Personal Targeted Spells"]},
        }), 30, "both")

        -- ============================================================
        -- API COMPATIBILITY OVERLAY (Group-frame Targeted Spells)
        --
        -- Group-frame Targeted Spells relies on UnitIsUnit comparing a
        -- nameplateXtarget against a party/raid token. Blizzard's
        -- 2026-04-07 hotfix made that combination return nil, with no
        -- in-addon workaround (the new PlayerIsSpellTarget API only
        -- answers for the player). DF.GroupTargetedSpellsAPIBlocked is
        -- set permanently at addon load in Features/TargetedSpells.lua,
        -- so this overlay is always visible on this page.
        --
        -- The overlay is parented to the page (not self.child) so it
        -- survives Refresh() rebuilds and floats above the scroll
        -- content.
        -- ============================================================
        if not self.apiBlockedOverlay then
            -- Parent to the page (ScrollFrame). The GUI window is in DIALOG
            -- strata; widgets inside it inherit DIALOG. We bump the overlay
            -- to FULLSCREEN_DIALOG and crank the frame level so it draws
            -- above everything in the page including the scroll child.
            local overlay = CreateFrame("Frame", nil, self, "BackdropTemplate")
            overlay:SetFrameStrata("FULLSCREEN_DIALOG")
            overlay:SetFrameLevel(500)
            overlay:SetAllPoints(self)
            overlay:EnableMouse(true) -- block clicks to underlying controls
            GUI:CreatePanelBackdrop(overlay, { bgColor = {0, 0, 0}, bgAlpha = 0.85, border = false })

            local title = overlay:CreateFontString(nil, "OVERLAY", "DFFontNormalHuge")
            title:SetPoint("CENTER", 0, 80)
            title:SetText(L["Not Available on Raid Frames"])
            title:SetTextColor(1, 0.82, 0)

            local body = overlay:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
            body:SetPoint("TOP", title, "BOTTOM", 0, -20)
            body:SetWidth(520)
            body:SetJustifyH("CENTER")
            body:SetText(L["Targeted Spells isn't available on raid frames — too many members share the same class, role, race, and sex to tell them apart.\n\nPersonal Targeted Spells still works for casts targeting you."])

            local gotoBtn = GUI:CreateButton(overlay, L["Open Personal Targeted Spells"], 260, 30, function()
                if GUI.SelectTab then GUI.SelectTab("indicators_personal_targeted") end
            end)
            gotoBtn:SetParent(overlay)
            gotoBtn:SetFrameStrata("FULLSCREEN_DIALOG")
            gotoBtn:SetFrameLevel(501)
            gotoBtn:SetPoint("TOP", body, "BOTTOM", 0, -25)

            self.apiBlockedOverlay = overlay
            overlay:Hide()
        end

        if GUI.SelectedMode == "raid" then
            self.apiBlockedOverlay:Show()
        else
            self.apiBlockedOverlay:Hide()
        end
    end)

    -- Stub kept for ABI compatibility — the overlay is now always visible
    -- so this is a no-op, but other code paths still call it.
    GUI.RefreshTargetedSpellsOverlay = function()
        local page = GUI.Pages and GUI.Pages["indicators_targetedspells"]
        if page and page.apiBlockedOverlay then
            if GUI.SelectedMode == "raid" then
                page.apiBlockedOverlay:Show()
            else
                page.apiBlockedOverlay:Hide()
            end
        end
    end

    -- ============================================================
    -- Indicators > Targeted List
    -- ============================================================
    -- Stacked cast-bar display showing enemy casts targeting party
    -- members. Replaces the group-frame Targeted Spells icons that
    -- Blizzard's 2026-04-07 UnitIsUnit hotfix permanently broke.
    -- Party-only feature; raid mode shows a redirect message.
    local pageTargetedList = CreateSubTab("indicators", "indicators_targetedlist", L["Targeted List"])
    BuildPage(pageTargetedList, function(self, db, Add, AddSpace, AddSyncPoint)
            -- Party-only feature: show message and return if in raid mode
            if GUI.SelectedMode == "raid" then
                Add(GUI:CreateHeader(self.child, L["Targeted List"]), 40, "both")
                Add(GUI:CreateLabel(self.child,
                    L["Targeted List is a Party-only feature. Switch to Party mode to configure."],
                    500, {r = 0.6, g = 0.6, b = 0.6}), 60, "both")
                return
            end

            -- Copy button at top
            Add(CreateCopyButton(self.child, {"targetedList"}, L["Targeted List"], "indicators_targetedlist"), 25, 2)

            AddSpace(6, "both")

            local currentSection = nil

            local function AddToSection(widget, height, col)
                Add(widget, height, col)
                if currentSection then currentSection:RegisterChild(widget) end
                return widget
            end

            local growthOptions = { UP = L["Up"], DOWN = L["Down"] }
            local iconPosOptions = { LEFT = L["Left"], RIGHT = L["Right"] }
            local stylePresetOptions = {
                DEFAULT = L["Default"],
                COMPACT = L["Compact"],
                DETAILED = L["Detailed"],
                MINIMAL = L["Minimal"],
            }


            local function HideTLOptions(d) return not d.targetedListEnabled end
            local function HideIconOptions(d) return not d.targetedListEnabled or not d.targetedListShowIcon end
            local function HideTargetNameOptions(d) return not d.targetedListEnabled or not d.targetedListShowTargetName end

            local function TargetedListUpdate()
                if DF.UpdateTargetedListLayout then DF:UpdateTargetedListLayout() end
            end

            -- ===== SETTINGS GROUP (Column 1) =====
            local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
            settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
            settingsGroup:AddWidget(GUI:CreateLabel(self.child,
                L["Shows a bar when an enemy is casting a spell targeting a party/raid member."], 250), 35)
            settingsGroup:AddWidget(GUI:CreateLabel(self.child,
                "|cff888888" .. L["To reposition: Unlock frames (/df unlock) and drag the mover."] .. "|r", 250), 30)
            settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable"], db, "targetedListEnabled", function()
                self:RefreshStates()
                if DF.ToggleTargetedList then DF:ToggleTargetedList(db.targetedListEnabled) end
                -- Reflect the enable change in test mode immediately (so disabling
                -- hides the test display, not just the live bars).
                if DF.UpdateAllTestTargetedList then DF:UpdateAllTestTargetedList() end
            end), 30)
            local tlImportantOnly = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Important Spells Only"], db, "targetedListImportantOnly", TargetedListUpdate), 30)
            tlImportantOnly.disableOn = HideTLOptions
            local tlHideOwn = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Casts Targeting You"], db, "targetedListHideOwnCasts", TargetedListUpdate), 30)
            tlHideOwn.disableOn = HideTLOptions
            local tlShowUntargeted = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Untargeted Casts"], db, "targetedListShowUntargeted", TargetedListUpdate), 30)
            tlShowUntargeted.disableOn = HideTLOptions
            local tlHideOOC = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Out-of-Combat Casts"], db, "targetedListHideOutOfCombat", TargetedListUpdate), 30)
            tlHideOOC.disableOn = HideTLOptions
            tlHideOOC.tooltip = L["Only show casts from enemies that are in combat. Filters out idle mobs casting nearby."]
            local tlMaxBars = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Bars"], 1, 20, 1, db, "targetedListMaxBars", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlMaxBars.disableOn = HideTLOptions
            Add(settingsGroup, nil, 1)

            AddSpace(10, "both")

            -- ===== LAYOUT SECTION =====
            local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, L["Layout"], true), 36, "both")
            currentSection = layoutSection

            local layoutGroup = GUI:CreateSettingsGroup(self.child, 260)
            layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Size & Spacing"]), 40)
            local tlW = layoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Bar Width"], 120, 600, 1, db, "targetedListWidth", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlW.disableOn = HideTLOptions
            local tlH = layoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Bar Height"], 14, 48, 1, db, "targetedListHeight", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlH.disableOn = HideTLOptions
            local tlSpace = layoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing"], 0, 10, 1, db, "targetedListSpacing", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlSpace.disableOn = HideTLOptions
            local tlGrowth = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growthOptions, db, "targetedListGrowth", TargetedListUpdate), 55)
            tlGrowth.disableOn = HideTLOptions
            local sortOptions = { NEWEST = L["Newest First"], OLDEST = L["Oldest First"], STATIC = L["Static (No Reorder)"] }
            local tlSort = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Sort Order"], sortOptions, db, "targetedListSortOrder", TargetedListUpdate), 55)
            tlSort.disableOn = HideTLOptions
            AddToSection(layoutGroup, nil, 1)

            local presetGroup = GUI:CreateSettingsGroup(self.child, 260)
            presetGroup:AddWidget(GUI:CreateHeader(self.child, L["Bar Style"]), 40)
            -- Picking a preset writes a bundle of settings to db
            -- (bar dimensions, show/hide toggles, font size, etc.)
            -- via DF:ApplyTargetedListPreset. After the bundle is
            -- applied the individual settings remain editable —
            -- the preset is a one-shot "start from this configuration"
            -- action, not a continuous override.
            local tlPreset = presetGroup:AddWidget(GUI:CreateDropdown(self.child, L["Bar Style"], stylePresetOptions, db, "targetedListStylePreset", function()
                if DF.ApplyTargetedListPreset then
                    DF:ApplyTargetedListPreset(db.targetedListStylePreset)
                end
                -- Also refresh GUI widgets so users see the preset's
                -- values reflected in the other sliders/checkboxes.
                if GUI and GUI.RefreshCurrentPage then
                    GUI:RefreshCurrentPage()
                end
                TargetedListUpdate()
            end), 55)
            tlPreset.disableOn = HideTLOptions
            local tlTexture = presetGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "targetedListTexture", TargetedListUpdate), 55)
            tlTexture.disableOn = HideTLOptions
            local tlBgAlpha = presetGroup:AddWidget(GUI:CreateSlider(self.child, L["Background Alpha"], 0, 1, 0.05, db, "targetedListBackgroundAlpha", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlBgAlpha.disableOn = HideTLOptions
            -- Stage 4.5: Show Border + Border Color replaced by
            -- CreateBorderControls. Targeted List is a list view (N bars),
            -- so animate is deliberately skipped (per-bar animation would
            -- be visual noise + a perf hit). class/role colour skipped
            -- because the bars represent SPELLS, not units. colour-by-time
            -- / colour-by-type also skipped (no aura state).
            GUI:CreateBorderControls(presetGroup, db, "targetedList", {
                parent       = self.child,
                include      = { alpha = true, inset = true, blendMode = true,
                                 gradient = true, shadow = true },
                fullUpdate   = TargetedListUpdate,
                lightUpdate  = TargetedListUpdate,
                lightColors  = function() if DF.LightweightUpdateTargetedListBorderColor then DF:LightweightUpdateTargetedListBorderColor() end end,
                refreshStates = function() self:RefreshStates() end,
                sizeMin = 1, sizeMax = 6, sizeStep = 1,
                -- Hide the whole border block when Targeted List is off, matching
                -- every other border block (Targeted Spells / Personal Targeted)
                -- and the rest of this page (which greys via disableOn=HideTLOptions).
                hideWhen      = HideTLOptions,
            })
            AddToSection(presetGroup, nil, 2)

            currentSection = nil
            AddSpace(10, "both")

            -- ===== APPEARANCE SECTION =====
            local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, L["Appearance"], true), 36, "both")
            currentSection = appearanceSection

            local colorGroup = GUI:CreateSettingsGroup(self.child, 260)
            colorGroup:AddWidget(GUI:CreateHeader(self.child, L["Bar Color"]), 40)
            local tlInterColor = colorGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Interruptible Color"], db, "targetedListInterruptibleColor", true, TargetedListUpdate, function() if DF.LightweightUpdateTargetedListBarColor then DF:LightweightUpdateTargetedListBarColor() end end, true), 35)
            tlInterColor.disableOn = HideTLOptions
            local tlUninterColor = colorGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Uninterruptible Color"], db, "targetedListUninterruptibleColor", true, TargetedListUpdate, function() if DF.LightweightUpdateTargetedListBarColor then DF:LightweightUpdateTargetedListBarColor() end end, true), 35)
            tlUninterColor.disableOn = HideTLOptions
            local tlSelfTargetEnabled = colorGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Self-Target Color"], db, "targetedListSelfTargetColorEnabled", function()
                self:RefreshStates()
                TargetedListUpdate()
            end), 30)
            tlSelfTargetEnabled.disableOn = HideTLOptions
            tlSelfTargetEnabled.tooltip = L["Highlight the bar when the enemy is casting at you."]
            local function HideSelfTargetOptions(d) return not d.targetedListEnabled or not d.targetedListSelfTargetColorEnabled end
            local tlSelfTargetColor = colorGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Self-Target Color"], db, "targetedListSelfTargetColor", true, TargetedListUpdate, nil, true), 35)
            tlSelfTargetColor.disableOn = HideSelfTargetOptions
            local tlHighlight = colorGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Highlight Important Spells"], db, "targetedListHighlightImportant", function()
                self:RefreshStates()
                TargetedListUpdate()
            end), 30)
            tlHighlight.disableOn = HideTLOptions
            local function HideHighlightOptions(d) return not d.targetedListEnabled or not d.targetedListHighlightImportant end
            local tlHighlightColor = colorGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Highlight Color"], db, "targetedListHighlightColor", true, TargetedListUpdate, function() if DF.LightweightUpdateTargetedListHighlightColor then DF:LightweightUpdateTargetedListHighlightColor() end end, true), 35)
            tlHighlightColor.disableOn = HideHighlightOptions
            local tlResetColors = colorGroup:AddWidget(GUI:CreateButton(self.child, L["Reset Colors to Default"], 200, 24, function()
                db.targetedListInterruptibleColor = {r = 1, g = 0.494, b = 0.137, a = 1}
                db.targetedListUninterruptibleColor = {r = 0.8, g = 0.302, b = 0.302, a = 1}
                db.targetedListSelfTargetColor = {r = 0.02, g = 0.776, b = 0.4, a = 0.2}
                db.targetedListHighlightColor = {r = 1, g = 0.8, b = 0, a = 1}
                db.targetedListBorderColor = {r = 0.18, g = 0.18, b = 0.18, a = 1}
                -- Refresh color swatches
                if tlInterColor.UpdateSwatch then tlInterColor:UpdateSwatch() end
                if tlUninterColor.UpdateSwatch then tlUninterColor:UpdateSwatch() end
                if tlSelfTargetColor.UpdateSwatch then tlSelfTargetColor:UpdateSwatch() end
                if tlHighlightColor.UpdateSwatch then tlHighlightColor:UpdateSwatch() end
                TargetedListUpdate()
                self:RefreshStates()
            end), 30)
            tlResetColors.disableOn = HideTLOptions
            AddToSection(colorGroup, nil, 1)

            local iconGroup = GUI:CreateSettingsGroup(self.child, 260)
            iconGroup:AddWidget(GUI:CreateHeader(self.child, L["Icon"]), 40)
            local tlShowIcon = iconGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Icon"], db, "targetedListShowIcon", function()
                self:RefreshStates()
                TargetedListUpdate()
            end), 30)
            tlShowIcon.disableOn = HideTLOptions
            local tlIconPos = iconGroup:AddWidget(GUI:CreateDropdown(self.child, L["Icon Position"], iconPosOptions, db, "targetedListIconPosition", TargetedListUpdate), 55)
            tlIconPos.disableOn = HideIconOptions
            local tlZoom = iconGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Zoom Icon"], db, "targetedListZoomIcon", TargetedListUpdate), 30)
            tlZoom.disableOn = HideIconOptions
            AddToSection(iconGroup, nil, 2)

            currentSection = nil
            AddSpace(10, "both")

            -- ===== TEXT SECTION =====
            local textSection = Add(GUI:CreateCollapsibleSection(self.child, L["Text"], true), 36, "both")
            currentSection = textSection

            local textToggleGroup = GUI:CreateSettingsGroup(self.child, 260)
            textToggleGroup:AddWidget(GUI:CreateHeader(self.child, L["Show"]), 40)
            local tlShowSpellName = textToggleGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Spell Name"], db, "targetedListShowSpellName", TargetedListUpdate), 30)
            tlShowSpellName.disableOn = HideTLOptions
            local tlShowTargetName = textToggleGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Target Name"], db, "targetedListShowTargetName", function()
                self:RefreshStates()
                TargetedListUpdate()
            end), 30)
            tlShowTargetName.disableOn = HideTLOptions
            local tlShowDuration = textToggleGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Duration"], db, "targetedListShowDuration", TargetedListUpdate), 30)
            tlShowDuration.disableOn = HideTLOptions
            local tlClassColor = textToggleGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Target Name Class Color"], db, "targetedListTargetNameClassColor", TargetedListUpdate), 30)
            tlClassColor.disableOn = HideTargetNameOptions
            local tlArrow = textToggleGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Arrow Prefix"], db, "targetedListShowArrowPrefix", TargetedListUpdate), 30)
            tlArrow.disableOn = HideTargetNameOptions
            local tlArrowSuffix = textToggleGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Arrow Suffix"], db, "targetedListShowArrowSuffix", TargetedListUpdate), 30)
            tlArrowSuffix.disableOn = HideTargetNameOptions
            AddToSection(textToggleGroup, nil, 1)

            local fontGroup = GUI:CreateSettingsGroup(self.child, 260)
            fontGroup:AddWidget(GUI:CreateHeader(self.child, L["Font"]), 40)
            local tlFont = fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "targetedListFont", TargetedListUpdate), 55)
            tlFont.disableOn = HideTLOptions
            local tlFontSize = fontGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 8, 24, 1, db, "targetedListFontSize", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlFontSize.disableOn = HideTLOptions
            local tlFontOutline = fontGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "targetedListFontOutline", TargetedListUpdate), 55)
            tlFontOutline.disableOn = HideTLOptions
            local tlFontShadow = fontGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "targetedListFontOutline", TargetedListUpdate), 30)
            tlFontShadow.disableOn = HideTLOptions
            AddToSection(fontGroup, nil, 2)

            currentSection = nil
            AddSpace(10, "both")

            -- ===== TEXT POSITION SECTION =====
            -- Per-element anchor + X/Y offset. Each text element
            -- (spell name, target name, duration) can be independently
            -- anchored to LEFT / CENTER / RIGHT within the bar's
            -- progress region with a pixel offset applied on top.
            local textPosSection = Add(GUI:CreateCollapsibleSection(self.child, L["Text Position"], true), 36, "both")
            currentSection = textPosSection

            local textAnchorOptions = { LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"] }
            local textAlignOptions = { LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"] }

            local spellNamePosGroup = GUI:CreateSettingsGroup(self.child, 260)
            spellNamePosGroup:AddWidget(GUI:CreateHeader(self.child, L["Spell Name"]), 40)
            local tlSNFontSize = spellNamePosGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 24, 1, db, "targetedListSpellNameFontSize", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlSNFontSize.disableOn = HideTLOptions
            local tlSNWidth = spellNamePosGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Text Width"], 0, 400, 1, db, "targetedListSpellNameWidth", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlSNWidth.disableOn = HideTLOptions
            local tlSNAnchor = spellNamePosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], textAnchorOptions, db, "targetedListSpellNameAnchor", TargetedListUpdate), 55)
            tlSNAnchor.disableOn = HideTLOptions
            local tlSNAlign = spellNamePosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Alignment"], textAlignOptions, db, "targetedListSpellNameAlign", TargetedListUpdate), 55)
            tlSNAlign.disableOn = HideTLOptions
            local tlSNX = spellNamePosGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -500, 500, 1, db, "targetedListSpellNameX", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlSNX.disableOn = HideTLOptions
            local tlSNY = spellNamePosGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -500, 500, 1, db, "targetedListSpellNameY", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlSNY.disableOn = HideTLOptions
            AddToSection(spellNamePosGroup, nil, 1)

            local targetNamePosGroup = GUI:CreateSettingsGroup(self.child, 260)
            targetNamePosGroup:AddWidget(GUI:CreateHeader(self.child, L["Target Name"]), 40)
            local tlTNFontSize = targetNamePosGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 24, 1, db, "targetedListTargetNameFontSize", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlTNFontSize.disableOn = HideTargetNameOptions
            local tlTNWidth = targetNamePosGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Text Width"], 0, 400, 1, db, "targetedListTargetNameWidth", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlTNWidth.disableOn = HideTargetNameOptions
            local tlTNAnchor = targetNamePosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], textAnchorOptions, db, "targetedListTargetNameAnchor", TargetedListUpdate), 55)
            tlTNAnchor.disableOn = HideTargetNameOptions
            local tlTNAlign = targetNamePosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Alignment"], textAlignOptions, db, "targetedListTargetNameAlign", TargetedListUpdate), 55)
            tlTNAlign.disableOn = HideTargetNameOptions
            local tlTNX = targetNamePosGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -500, 500, 1, db, "targetedListTargetNameX", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlTNX.disableOn = HideTargetNameOptions
            local tlTNY = targetNamePosGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -500, 500, 1, db, "targetedListTargetNameY", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlTNY.disableOn = HideTargetNameOptions
            AddToSection(targetNamePosGroup, nil, 2)

            local function HideDurationPosOptions(d) return not d.targetedListEnabled or not d.targetedListShowDuration end
            local durationPosGroup = GUI:CreateSettingsGroup(self.child, 260)
            durationPosGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration"]), 40)
            local tlDurFontSize = durationPosGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 24, 1, db, "targetedListDurationFontSize", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlDurFontSize.disableOn = HideDurationPosOptions
            local tlDurAnchor = durationPosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], textAnchorOptions, db, "targetedListDurationAnchor", TargetedListUpdate), 55)
            tlDurAnchor.disableOn = HideDurationPosOptions
            local tlDurAlign = durationPosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Alignment"], textAlignOptions, db, "targetedListDurationAlign", TargetedListUpdate), 55)
            tlDurAlign.disableOn = HideDurationPosOptions
            local tlDurX = durationPosGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -500, 500, 1, db, "targetedListDurationX", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlDurX.disableOn = HideDurationPosOptions
            local tlDurY = durationPosGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -500, 500, 1, db, "targetedListDurationY", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlDurY.disableOn = HideDurationPosOptions
            AddToSection(durationPosGroup, nil, 1)

            local interruptPosGroup = GUI:CreateSettingsGroup(self.child, 260)
            interruptPosGroup:AddWidget(GUI:CreateHeader(self.child, L["Interrupt Text"]), 40)
            local tlIntFontSize = interruptPosGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 24, 1, db, "targetedListInterruptTextFontSize", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlIntFontSize.disableOn = HideTLOptions
            local tlIntWidth = interruptPosGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Text Width"], 0, 400, 1, db, "targetedListInterruptTextWidth", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlIntWidth.disableOn = HideTLOptions
            local tlIntAnchor = interruptPosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], textAnchorOptions, db, "targetedListInterruptTextAnchor", TargetedListUpdate), 55)
            tlIntAnchor.disableOn = HideTLOptions
            local tlIntAlign = interruptPosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Alignment"], textAlignOptions, db, "targetedListInterruptTextAlign", TargetedListUpdate), 55)
            tlIntAlign.disableOn = HideTLOptions
            local tlIntX = interruptPosGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -500, 500, 1, db, "targetedListInterruptTextX", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlIntX.disableOn = HideTLOptions
            local tlIntY = interruptPosGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -500, 500, 1, db, "targetedListInterruptTextY", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlIntY.disableOn = HideTLOptions
            AddToSection(interruptPosGroup, nil, 2)

            currentSection = nil
            AddSpace(10, "both")

            -- ===== BEHAVIOR SECTION =====
            local behaviorSection = Add(GUI:CreateCollapsibleSection(self.child, L["Behavior"], true), 36, "both")
            currentSection = behaviorSection

            local timingGroup = GUI:CreateSettingsGroup(self.child, 260)
            timingGroup:AddWidget(GUI:CreateHeader(self.child, L["Timing"]), 40)
            local tlFadeOut = timingGroup:AddWidget(GUI:CreateSlider(self.child, L["Fade Out Duration"], 0, 1, 0.05, db, "targetedListFadeOutDuration", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlFadeOut.disableOn = HideTLOptions
            local tlFlashDur = timingGroup:AddWidget(GUI:CreateSlider(self.child, L["Interrupted Flash Duration"], 0, 2, 0.1, db, "targetedListInterruptedFlashDuration", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlFlashDur.disableOn = HideTLOptions
            AddToSection(timingGroup, nil, 1)

            currentSection = nil

            -- See Also links
            AddSpace(20, "both")
            Add(GUI:CreateSeeAlso(self.child, {
                {pageId = "indicators_targetedspells", label = L["Targeted Spells"]},
                {pageId = "indicators_personal_targeted", label = L["Personal Targeted"]},
            }), 30, "both")
        end)

    -- Indicators > Personal Targeted Spells (center of screen display for player)
    local pagePersonalTargeted = CreateSubTab("indicators", "indicators_personal_targeted", L["Personal Targeted"])
    BuildPage(pagePersonalTargeted, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"personalTargeted"}, L["Personal Targeted"], "indicators_personal_targeted"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local growthOptions = { UP= L["Up"], DOWN= L["Down"], LEFT= L["Left"], RIGHT= L["Right"], CENTER_H= L["Center (Horizontal)"], CENTER_V= L["Center (Vertical)"] }
        
        local function HidePersonalOptions(d) return not d.personalTargetedSpellEnabled end
        local function HidePersonalDurationOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowDuration end
        
        local function PersonalTargetedUpdate()
            if DF.UpdatePersonalTargetedSpellsPosition then DF:UpdatePersonalTargetedSpellsPosition() end
            if DF.UpdateTestPersonalTargetedSpells then DF:UpdateTestPersonalTargetedSpells() end
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Shows incoming targeted spells on YOU in the center of your screen."], 250), 30)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, L["To reposition: Unlock frames (/df unlock) and drag the mover."], 250), 30)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Personal Targeted Spells"], db, "personalTargetedSpellEnabled", function()
            self:RefreshStates()
            if DF.TogglePersonalTargetedSpells then DF:TogglePersonalTargetedSpells(db.personalTargetedSpellEnabled) end
        end), 30)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Important Spells Only"], db, "personalTargetedSpellImportantOnly", PersonalTargetedUpdate), 30)
        Add(settingsGroup, nil, 1)
        
        -- ===== CONTENT TYPES GROUP (Column 2) =====
        local contentGroup = GUI:CreateSettingsGroup(self.child, 280)
        contentGroup:AddWidget(GUI:CreateHeader(self.child, L["Content Types"]), 40)
        contentGroup:AddWidget(GUI:CreateLabel(self.child, L["Show in content types:"], 250), 25)
        local ptsOpenWorld = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Open World"], db, "personalTargetedSpellInOpenWorld", nil), 25)
        ptsOpenWorld.disableOn = HidePersonalOptions
        ptsOpenWorld.hideOn = function() return GUI.SelectedMode == "raid" end
        local ptsDungeons = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Dungeons"], db, "personalTargetedSpellInDungeons", nil), 25)
        ptsDungeons.disableOn = HidePersonalOptions
        ptsDungeons.hideOn = function() return GUI.SelectedMode == "raid" end
        local ptsRaids = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Raids"], db, "personalTargetedSpellInRaids", nil), 25)
        ptsRaids.disableOn = HidePersonalOptions
        ptsRaids.hideOn = function() return GUI.SelectedMode == "raid" end
        local ptsArena = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Arena"], db, "personalTargetedSpellInArena", nil), 25)
        ptsArena.disableOn = HidePersonalOptions
        ptsArena.hideOn = function() return GUI.SelectedMode == "raid" end
        local ptsBattlegrounds = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Battlegrounds"], db, "personalTargetedSpellInBattlegrounds", nil), 25)
        ptsBattlegrounds.disableOn = HidePersonalOptions
        ptsBattlegrounds.hideOn = function() return GUI.SelectedMode == "raid" end
        contentGroup:AddWidget(GUI:CreateLabel(self.child, L["Content type filters configured in Party tab."], 250), 25)
        contentGroup.hideOn = HidePersonalOptions
        Add(contentGroup, nil, 2)
        
        AddSpace(10, "both")
        
        -- ===== LAYOUT SECTION =====
        local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, L["Layout"], true), 36, "both")
        currentSection = layoutSection
        
        -- Size Group (col1)
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 260)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Size"]), 40)
        local ptsSize = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 20, 80, 1, db, "personalTargetedSpellSize", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsSize.disableOn = HidePersonalOptions
        local ptsScale = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "personalTargetedSpellScale", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsScale.disableOn = HidePersonalOptions
        local ptsAlpha = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.0, 1.0, 0.05, db, "personalTargetedSpellAlpha", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsAlpha.disableOn = HidePersonalOptions
        local ptsSpacing = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing"], 0, 20, 1, db, "personalTargetedSpellSpacing", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsSpacing.disableOn = HidePersonalOptions
        local ptsMaxIcons = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Icons"], 1, 10, 1, db, "personalTargetedSpellMaxIcons", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsMaxIcons.disableOn = HidePersonalOptions
        AddToSection(sizeGroup, nil, 1)
        
        -- Growth Group (col2)
        local growthGroup = GUI:CreateSettingsGroup(self.child, 260)
        growthGroup:AddWidget(GUI:CreateHeader(self.child, L["Growth"]), 40)
        local ptsGrowth = growthGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growthOptions, db, "personalTargetedSpellGrowth", PersonalTargetedUpdate), 55)
        ptsGrowth.disableOn = HidePersonalOptions
        AddToSection(growthGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== APPEARANCE SECTION =====
        local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, L["Appearance"], true), 36, "both")
        currentSection = appearanceSection
        
        -- Border Group (col1) — Stage 4.4: 3 hand-rolled border widgets
        -- (Show / Size / Color) replaced by CreateBorderControls. include
        -- set tailored for a "needs attention" alert surface (Personal
        -- Targeted = spells targeting you). Skipped: offset (icon has its
        -- own positioning), classColor / roleColor (spell alert, not unit
        -- identity), colorByTime / colorByType (no aura-state context).
        local borderGroup = GUI:CreateSettingsGroup(self.child, 260)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        GUI:CreateBorderControls(borderGroup, db, "personalTargetedSpell", {
            parent       = self.child,
            include      = { alpha = true, inset = true, blendMode = true,
                             gradient = true, shadow = true, animate = true },
            fullUpdate   = PersonalTargetedUpdate,
            lightUpdate  = PersonalTargetedUpdate,
            lightColors  = PersonalTargetedUpdate,
            refreshStates = function() self:RefreshStates() end,
            hideWhen     = function(d) return not d.personalTargetedSpellEnabled end,
            sizeMin = 0, sizeMax = 5, sizeStep = 1,  -- 0 = animation-only (no solid edge)
        })
        AddToSection(borderGroup, nil, 1)
        
        -- Duration Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 260)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Text"]), 40)
        local ptsDuration = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Duration"], db, "personalTargetedSpellShowDuration", function()
            self:RefreshStates()
            PersonalTargetedUpdate()
        end), 30)
        ptsDuration.disableOn = HidePersonalOptions
        -- The cooldown swipe is the radial cooldown sweep on the icon (independent
        -- of the numeric duration text), so it's gated only on the feature itself.
        local ptsSwipe = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Cooldown Swipe"], db, "personalTargetedSpellShowSwipe", PersonalTargetedUpdate), 30)
        ptsSwipe.disableOn = HidePersonalOptions
        local ptsDurFont = durationGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "personalTargetedSpellDurationFont", PersonalTargetedUpdate), 55)
        ptsDurFont.disableOn = HidePersonalDurationOptions
        local ptsDurScale = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.1, db, "personalTargetedSpellDurationScale", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsDurScale.disableOn = HidePersonalDurationOptions
        local ptsDurOutline = durationGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "personalTargetedSpellDurationOutline", PersonalTargetedUpdate), 55)
        ptsDurOutline.disableOn = HidePersonalDurationOptions
        local ptsDurShadow = durationGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "personalTargetedSpellDurationOutline", PersonalTargetedUpdate), 30)
        ptsDurShadow.disableOn = HidePersonalDurationOptions
        local ptsDurX = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -20, 20, 1, db, "personalTargetedSpellDurationX", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsDurX.disableOn = HidePersonalDurationOptions
        local ptsDurY = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -20, 20, 1, db, "personalTargetedSpellDurationY", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsDurY.disableOn = HidePersonalDurationOptions
        local ptsDurColor = durationGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "personalTargetedSpellDurationColor", false, PersonalTargetedUpdate), 35)
        ptsDurColor.disableOn = HidePersonalDurationOptions
        AddToSection(durationGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== IMPORTANT SPELLS SECTION =====
        local highlightSection = Add(GUI:CreateCollapsibleSection(self.child, L["Important Spells"], true), 36, "both")
        currentSection = highlightSection
        
        local function HidePersonalHighlightOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellHighlightImportant end

        local highlightGroup = GUI:CreateSettingsGroup(self.child, 260)
        highlightGroup:AddWidget(GUI:CreateHeader(self.child, L["Highlight Settings"]), 40)
        local ptsHighlight = highlightGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Highlight Important Spells"], db, "personalTargetedSpellHighlightImportant", function()
            self:RefreshStates()
            PersonalTargetedUpdate()
        end), 30)
        ptsHighlight.disableOn = HidePersonalOptions
        -- Important Spell Border: the highlight on its own DF.Border (full toolkit),
        -- gated by the Highlight Important Spells toggle above.
        GUI:CreateBorderControls(highlightGroup, db, "personalTargetedSpellImportant", {
            parent        = self.child,
            noShowToggle  = true,  -- the Highlight Important Spells checkbox is the gate
            include       = { alpha = true, inset = true, blendMode = true,
                              gradient = true, shadow = true, animate = true },
            fullUpdate    = PersonalTargetedUpdate,
            lightUpdate   = PersonalTargetedUpdate,
            lightColors   = PersonalTargetedUpdate,
            refreshStates = function() self:RefreshStates() end,
            hideWhen      = HidePersonalHighlightOptions,
            sizeMin = 0, sizeMax = 8, sizeStep = 1,
        })
        AddToSection(highlightGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== INTERRUPTED VISUAL SECTION =====
        local interruptSection = Add(GUI:CreateCollapsibleSection(self.child, L["Interrupted Visual"], true), 36, "both")
        currentSection = interruptSection
        
        local function HideInterruptOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowInterrupted end
        local function HideInterruptXOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowInterrupted or not d.personalTargetedSpellInterruptedShowX end
        
        local interruptGroup = GUI:CreateSettingsGroup(self.child, 260)
        interruptGroup:AddWidget(GUI:CreateHeader(self.child, L["Interrupt Settings"]), 40)
        local ptsInterrupted = interruptGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Interrupted Visual"], db, "personalTargetedSpellShowInterrupted", function()
            self:RefreshStates()
            PersonalTargetedUpdate()
        end), 30)
        ptsInterrupted.disableOn = HidePersonalOptions
        local ptsInterruptDur = interruptGroup:AddWidget(GUI:CreateSlider(self.child, L["Duration"], 0.1, 2.0, 0.1, db, "personalTargetedSpellInterruptedDuration", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsInterruptDur.disableOn = HideInterruptOptions
        local ptsInterruptTint = interruptGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Tint Color"], db, "personalTargetedSpellInterruptedTintColor", false, PersonalTargetedUpdate), 35)
        ptsInterruptTint.disableOn = HideInterruptOptions
        local ptsInterruptTintAlpha = interruptGroup:AddWidget(GUI:CreateSlider(self.child, L["Tint Opacity"], 0, 1, 0.1, db, "personalTargetedSpellInterruptedTintAlpha", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsInterruptTintAlpha.disableOn = HideInterruptOptions
        AddToSection(interruptGroup, nil, 1)
        
        local xMarkGroup = GUI:CreateSettingsGroup(self.child, 260)
        xMarkGroup:AddWidget(GUI:CreateHeader(self.child, L["X Mark"]), 40)
        local ptsShowX = xMarkGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show X Mark"], db, "personalTargetedSpellInterruptedShowX", function()
            self:RefreshStates()
            PersonalTargetedUpdate()
        end), 30)
        ptsShowX.disableOn = HideInterruptOptions
        local ptsXColor = xMarkGroup:AddWidget(GUI:CreateColorPicker(self.child, L["X Color"], db, "personalTargetedSpellInterruptedXColor", false, PersonalTargetedUpdate), 35)
        ptsXColor.disableOn = HideInterruptXOptions
        local ptsXSize = xMarkGroup:AddWidget(GUI:CreateSlider(self.child, L["X Size"], 8, 40, 1, db, "personalTargetedSpellInterruptedXSize", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsXSize.disableOn = HideInterruptXOptions
        xMarkGroup.hideOn = HideInterruptOptions
        AddToSection(xMarkGroup, nil, 2)
        
        currentSection = nil
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "indicators_targetedspells", label = L["Targeted Spells (on frames)"]},
        }), 30, "both")
    end)
    
    -- Indicators > Icons (All icons with collapsible sections)
    local pageIcons = CreateSubTab("indicators", "indicators_icons", L["Icons"])
    BuildPage(pageIcons, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"roleIcon", "leaderIcon", "raidTargetIcon", "readyCheckIcon", "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon", "vehicleIcon", "raidRoleIcon", "bgCarrierIcon", "statusIconFont", "statusIconFontSize", "statusIconFontOutline"}, L["Icons"], "indicators_icons"), 25, 2)
        
        local anchorOptions = {
            CENTER = L["Center"],
            TOP = L["Top"],
            BOTTOM = L["Bottom"],
            LEFT = L["Left"],
            RIGHT = L["Right"],
            TOPLEFT = L["Top Left"],
            TOPRIGHT = L["Top Right"],
            BOTTOMLEFT = L["Bottom Left"],
            BOTTOMRIGHT = L["Bottom Right"],
        }
        
        local roleStyleOptions = {
            BLIZZARD = L["Blizzard"],
            CUSTOM = "DF Icons",
            EXTERNAL = L["External"],
        }
        
        -- ============================================
        -- ICON TEXT SETTINGS (Collapsible, at top)
        -- ============================================
        local textSection = Add(GUI:CreateCollapsibleSection(self.child, L["Icon Text Settings"], false, 270), 28, 1)
        
        local textLabel = Add(GUI:CreateLabel(self.child, L["Font settings for icons displayed as text (Summon, Res, AFK, etc.)"], 240), 30, 1)
        textSection:RegisterChild(textLabel)
        
        local textFont = Add(GUI:CreateFontDropdown(self.child, L["Font"], db, "statusIconFont", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 55, 1)
        textSection:RegisterChild(textFont)
        
        local textSize = Add(GUI:CreateSlider(self.child, L["Font Size"], 8, 24, 1, db, "statusIconFontSize", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55, 1)
        textSection:RegisterChild(textSize)
        
        local textOutline = Add(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "statusIconFontOutline", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 55, 1)
        textSection:RegisterChild(textOutline)

        local textShadow = Add(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "statusIconFontOutline", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30, 1)
        textSection:RegisterChild(textShadow)

        local shadowNote = Add(GUI:CreateLabel(self.child, L["Shadow offset and colour are controlled in General > Global Fonts."], 240), 30, 1)
        textSection:RegisterChild(shadowNote)
        shadowNote.hideOn = function(d) return not DF:OutlineHasShadow(d.statusIconFontOutline) end
        
        -- Text Colors header
        local colorsLabel = Add(GUI:CreateLabel(self.child, L["Text Colors:"], 240), 25, 1)
        textSection:RegisterChild(colorsLabel)
        
        local summonColor = Add(GUI:CreateColorPicker(self.child, L["Summon"], db, "summonIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(summonColor)
        
        local resColor = Add(GUI:CreateColorPicker(self.child, L["Resurrection"], db, "resurrectionIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(resColor)
        
        local afkColor = Add(GUI:CreateColorPicker(self.child, L["AFK"], db, "afkIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(afkColor)
        
        local phasedColor = Add(GUI:CreateColorPicker(self.child, L["Phased"], db, "phasedIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(phasedColor)
        
        local vehicleColor = Add(GUI:CreateColorPicker(self.child, L["Vehicle"], db, "vehicleIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(vehicleColor)
        
        local raidRoleColor = Add(GUI:CreateColorPicker(self.child, L["Raid Role (MT/MA)"], db, "raidRoleIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(raidRoleColor)

        local bgCarrierColor = Add(GUI:CreateColorPicker(self.child, L["BG Carrier"], db, "bgCarrierIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(bgCarrierColor)

        -- ============================================
        -- ROLE ICON (Collapsible)
        -- ============================================
        local roleSection = Add(GUI:CreateCollapsibleSection(self.child, L["Role Icon"], false, 270), 28, 1)

        -- Header preview: the Tank/Healer/DPS icons in the currently selected
        -- style. Rebuilt live whenever the style, an external path, or a
        -- per-role Show toggle changes. Each role's icon desaturates when its
        -- Show toggle is off (matching the other icon sections' previews);
        -- the whole preview dims only when all three roles are off.
        local roleShowKeys = { TANK = "roleIconShowTank", HEALER = "roleIconShowHealer", DAMAGER = "roleIconShowDPS" }
        local function UpdateRolePreview()
            if not roleSection.SetPreviewIcons then return end
            local icons = {}
            local anyShown = false
            for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
                -- tex may be an atlas name (no coords) or a texture path (+coords).
                local tex, l, r, t, b = DF:GetRoleIconTexture(db, role)
                if tex then
                    local shown = db[roleShowKeys[role]] ~= false
                    anyShown = anyShown or shown
                    icons[#icons + 1] = { texture = tex, coords = l and { l, r, t, b } or nil, desaturate = not shown }
                end
            end
            roleSection:SetPreviewIcons(icons)
            if roleSection.SetPreviewDimmed then roleSection:SetPreviewDimmed(not anyShown) end
        end

        -- Small gap between the section header and the first box.
        local roleHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        roleSection:RegisterChild(roleHeaderGap)

        -- Settings
        local roleSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "roleIcon:Settings" })
        roleSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        roleSettings:AddWidget(GUI:CreateDropdown(self.child, L["Icon Style"], roleStyleOptions, db, "roleIconStyle", function() DF:UpdateAllRoleIcons(); UpdateRolePreview() end), 55)
        local roleExtTank = roleSettings:AddWidget(GUI:CreateEditBox(self.child, L["Tank Icon Path"], db, "roleIconExternalTank", function() DF:UpdateAllRoleIcons(); UpdateRolePreview() end, nil, "Interface\\MyIcons\\Tank.tga"), 55)
        roleExtTank.hideOn = function(d) return d.roleIconStyle ~= "EXTERNAL" end
        local roleExtHealer = roleSettings:AddWidget(GUI:CreateEditBox(self.child, L["Healer Icon Path"], db, "roleIconExternalHealer", function() DF:UpdateAllRoleIcons(); UpdateRolePreview() end, nil, "Interface\\MyIcons\\Healer.tga"), 55)
        roleExtHealer.hideOn = function(d) return d.roleIconStyle ~= "EXTERNAL" end
        local roleExtDPS = roleSettings:AddWidget(GUI:CreateEditBox(self.child, L["DPS Icon Path"], db, "roleIconExternalDPS", function() DF:UpdateAllRoleIcons(); UpdateRolePreview() end, nil, "Interface\\MyIcons\\DPS.tga"), 55)
        roleExtDPS.hideOn = function(d) return d.roleIconStyle ~= "EXTERNAL" end
        local roleExtNote = roleSettings:AddWidget(GUI:CreateLabel(self.child, L["Paths are relative to your WoW folder and must start with Interface\\. Pasting a full path works — anything before 'Interface' is stripped. Leave empty for DF Icons."], 250), 70)
        roleExtNote.hideOn = function(d) return d.roleIconStyle ~= "EXTERNAL" end
        -- Per-role filters: which roles ever show an icon (global — apply in and
        -- out of combat). The Hide In Combat toggle (Appearance) is an independent gate.
        roleSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show Tank"], db, "roleIconShowTank", function() DF:UpdateAllRoleIcons(); UpdateRolePreview() end), 30)
        roleSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show Healer"], db, "roleIconShowHealer", function() DF:UpdateAllRoleIcons(); UpdateRolePreview() end), 30)
        roleSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show DPS"], db, "roleIconShowDPS", function() DF:UpdateAllRoleIcons(); UpdateRolePreview() end), 30)
        Add(roleSettings, nil, 1)
        roleSection:RegisterChild(roleSettings)

        -- Appearance
        local roleAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "roleIcon:Appearance" })
        roleAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        roleAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "roleIconScale", nil, function() DF:LightweightUpdateIconPosition("role") end, true), 55)
        roleAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "roleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("role") end, true), 55)
        roleAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "roleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("role") end, true), 55)
        roleAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide In Combat"], db, "roleIconHideInCombat", function() DF:UpdateAllRoleIcons() end), 30)
        Add(roleAppearance, nil, 1)
        roleSection:RegisterChild(roleAppearance)

        -- Position
        local rolePosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "roleIcon:Position" })
        rolePosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        rolePosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "roleIconAnchor", function() DF:LightweightUpdateIconPosition("role") end), 55)
        rolePosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "roleIconX", nil, function() DF:LightweightUpdateIconPosition("role") end, true), 55)
        rolePosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "roleIconY", nil, function() DF:LightweightUpdateIconPosition("role") end, true), 55)
        Add(rolePosition, nil, 1)
        roleSection:RegisterChild(rolePosition)

        -- Initial header preview for the current style.
        UpdateRolePreview()

        -- ============================================
        -- STATUS-ICON HEADER PREVIEWS
        -- Each status-icon section shows a representative swatch on its header
        -- (or the configured status text when "Show as Text" is on), greyed out
        -- when the section is disabled. Refreshers are registered globally and
        -- re-run by hooked frame-update functions, so previews track live
        -- enable/text changes without touching every control's callback.
        -- ============================================
        if not DF._iconPreviewHooked then
            DF._iconPreviewHooked = true
            if DF.UpdateAllFrames then
                hooksecurefunc(DF, "UpdateAllFrames", function() DF:RefreshIconPreviews() end)
            end
            if DF.UpdateAllFramesStatusIcons then
                hooksecurefunc(DF, "UpdateAllFramesStatusIcons", function() DF:RefreshIconPreviews() end)
            end
        end
        if DF.iconPreviewRefreshers then wipe(DF.iconPreviewRefreshers) end

        local function WireStatusPreview(section, opts)
            local function refresh(force)
                if not section.SetPreviewIcons then return end
                if not force and not section:IsVisible() then return end
                local enabled = (not opts.enableKey) or (db[opts.enableKey] ~= false)
                -- Text entries use the icon's configured status-text colour so the
                -- preview matches the frame (e.g. <prefix>IconTextColor).
                local colorKey = opts.enableKey and opts.enableKey:gsub("Enabled$", "TextColor")
                local textColor = colorKey and db[colorKey]
                local entries = {}
                if opts.showTextKey and db[opts.showTextKey] then
                    for _, key in ipairs(opts.texts or {}) do
                        entries[#entries + 1] = { text = db[key] or key, color = textColor }
                    end
                else
                    for _, ic in ipairs(opts.icons or {}) do
                        if type(ic) == "table" then
                            -- table form: { texture = <path OR atlas name>, coords = {l,r,t,b} }
                            -- for icons that need a texcoord slice (e.g. raid-target markers
                            -- off the shared UI-RaidTargetingIcons sheet). SetIconTextureOrAtlas
                            -- auto-detects atlas vs path, so a plain texture string still works.
                            entries[#entries + 1] = { texture = ic.texture, coords = ic.coords, inset = ic.inset }
                        else
                            entries[#entries + 1] = { texture = ic }
                        end
                    end
                end
                for _, e in ipairs(entries) do e.desaturate = not enabled end
                section:SetPreviewIcons(entries)
                section:SetPreviewDimmed(not enabled)
            end
            if DF.iconPreviewRefreshers then table.insert(DF.iconPreviewRefreshers, refresh) end
            refresh(true)
        end

        -- ============================================
        -- LEADER ICON (Collapsible)
        -- ============================================
        local leaderSection = Add(GUI:CreateCollapsibleSection(self.child, L["Leader Icon"], false, 270), 28, 1)
        WireStatusPreview(leaderSection, { enableKey = "leaderIconEnabled", icons = { "Interface\\GroupFrame\\UI-Group-LeaderIcon" } })
        
        -- Small gap between the section header and the first box.
        local leaderHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        leaderSection:RegisterChild(leaderHeaderGap)

        -- Settings
        local leaderSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "leaderIcon:Settings" })
        leaderSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        leaderSettings.disableChildrenOn = function(d) return not d.leaderIconEnabled end
        local leaderIconEnableCb = leaderSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Leader Icon"], db, "leaderIconEnabled", function() DF:UpdateAllFrames() end), 30)
        leaderIconEnableCb.keepEnabled = true
        Add(leaderSettings, nil, 1)
        leaderSection:RegisterChild(leaderSettings)

        -- Appearance
        local leaderAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "leaderIcon:Appearance" })
        leaderAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        leaderAppearance.disableChildrenOn = function(d) return not d.leaderIconEnabled end
        leaderAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "leaderIconScale", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55)
        leaderAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "leaderIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("leader") end, true), 55)
        leaderAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "leaderIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("leader") end, true), 55)
        leaderAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "leaderIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(leaderAppearance, nil, 1)
        leaderSection:RegisterChild(leaderAppearance)

        -- Position
        local leaderPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "leaderIcon:Position" })
        leaderPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        leaderPosition.disableChildrenOn = function(d) return not d.leaderIconEnabled end
        leaderPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "leaderIconAnchor", function() DF:LightweightUpdateIconPosition("leader") end), 55)
        leaderPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "leaderIconX", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55)
        leaderPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "leaderIconY", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55)
        Add(leaderPosition, nil, 1)
        leaderSection:RegisterChild(leaderPosition)
        
        -- ============================================
        -- RAID TARGET ICON (Collapsible)
        -- ============================================
        local raidTargetSection = Add(GUI:CreateCollapsibleSection(self.child, L["Target Marker Icon"], false, 270), 28, 1)
        -- Header preview: the four most-used markers (square / cross / triangle / circle),
        -- sliced from the classic raid-target sheet via texcoords (the atlas form won't render here).
        WireStatusPreview(raidTargetSection, { enableKey = "raidTargetIconEnabled", icons = {
            { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.25, 0.5,  0.25, 0.5  }, inset = 2 },  -- square   (6)
            { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.5,  0.75, 0.25, 0.5  }, inset = 2 },  -- cross    (7)
            { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.75, 1.0,  0.0,  0.25 }, inset = 2 },  -- triangle (4)
            { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.25, 0.5,  0.0,  0.25 }, inset = 2 },  -- circle   (2)
        } })
        
        -- Small gap between the section header and the first box.
        local rtHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        raidTargetSection:RegisterChild(rtHeaderGap)

        -- Settings
        local rtSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "raidTargetIcon:Settings" })
        rtSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        rtSettings.disableChildrenOn = function(d) return not d.raidTargetIconEnabled end
        local raidTargetIconEnableCb = rtSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Target Marker Icon"], db, "raidTargetIconEnabled", function() DF:UpdateAllFrames() end), 30)
        raidTargetIconEnableCb.keepEnabled = true
        Add(rtSettings, nil, 1)
        raidTargetSection:RegisterChild(rtSettings)

        -- Appearance
        local rtAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "raidTargetIcon:Appearance" })
        rtAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        rtAppearance.disableChildrenOn = function(d) return not d.raidTargetIconEnabled end
        rtAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "raidTargetIconScale", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55)
        rtAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "raidTargetIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("raidTarget") end, true), 55)
        rtAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "raidTargetIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("raidTarget") end, true), 55)
        rtAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "raidTargetIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(rtAppearance, nil, 1)
        raidTargetSection:RegisterChild(rtAppearance)

        -- Position
        local rtPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "raidTargetIcon:Position" })
        rtPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        rtPosition.disableChildrenOn = function(d) return not d.raidTargetIconEnabled end
        rtPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "raidTargetIconAnchor", function() DF:LightweightUpdateIconPosition("raidTarget") end), 55)
        rtPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "raidTargetIconX", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55)
        rtPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "raidTargetIconY", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55)
        Add(rtPosition, nil, 1)
        raidTargetSection:RegisterChild(rtPosition)
        
        -- ============================================
        -- READY CHECK ICON (Collapsible)
        -- ============================================
        local readySection = Add(GUI:CreateCollapsibleSection(self.child, L["Ready Check Icon"], false, 270), 28, 1)
        WireStatusPreview(readySection, { enableKey = "readyCheckIconEnabled", icons = { "UI-LFG-ReadyMark-Raid" } })
        
        -- Small gap between the section header and the first box.
        local rcHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        readySection:RegisterChild(rcHeaderGap)

        -- Settings
        local rcSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "readyCheckIcon:Settings" })
        rcSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        rcSettings.disableChildrenOn = function(d) return not d.readyCheckIconEnabled end
        local readyCheckIconEnableCb = rcSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Ready Check Icon"], db, "readyCheckIconEnabled", function() DF:UpdateAllFrames() end), 30)
        readyCheckIconEnableCb.keepEnabled = true
        rcSettings:AddWidget(GUI:CreateSlider(self.child, L["Persist (seconds)"], 0, 15, 1, db, "readyCheckIconPersist"), 55)
        Add(rcSettings, nil, 1)
        readySection:RegisterChild(rcSettings)

        -- Appearance
        local rcAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "readyCheckIcon:Appearance" })
        rcAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        rcAppearance.disableChildrenOn = function(d) return not d.readyCheckIconEnabled end
        rcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "readyCheckIconScale", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55)
        rcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "readyCheckIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("readyCheck") end, true), 55)
        rcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "readyCheckIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("readyCheck") end, true), 55)
        rcAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "readyCheckIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(rcAppearance, nil, 1)
        readySection:RegisterChild(rcAppearance)

        -- Position
        local rcPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "readyCheckIcon:Position" })
        rcPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        rcPosition.disableChildrenOn = function(d) return not d.readyCheckIconEnabled end
        rcPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "readyCheckIconAnchor", function() DF:LightweightUpdateIconPosition("readyCheck") end), 55)
        rcPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "readyCheckIconX", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55)
        rcPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "readyCheckIconY", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55)
        Add(rcPosition, nil, 1)
        readySection:RegisterChild(rcPosition)
        
        -- ============================================
        -- SUMMON ICON (Collapsible)
        -- ============================================
        local summonSection = Add(GUI:CreateCollapsibleSection(self.child, L["Summon Icon"], false, 270), 28, 1)
        WireStatusPreview(summonSection, { enableKey = "summonIconEnabled", showTextKey = "summonIconShowText", icons = { "RaidFrame-Icon-SummonPending" }, texts = { "summonIconTextPending" } })
        
        -- Small gap between the section header and the first box.
        local sumHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        summonSection:RegisterChild(sumHeaderGap)

        -- Settings
        local sumSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "summonIcon:Settings" })
        sumSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        sumSettings.disableChildrenOn = function(d) return not d.summonIconEnabled end
        local summonIconEnableCb = sumSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Summon Icon"], db, "summonIconEnabled", function() DF:UpdateAllFrames() end), 30)
        summonIconEnableCb.keepEnabled = true
        sumSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "summonIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        sumSettings:AddWidget(GUI:CreateEditBox(self.child, L["Pending Text"], db, "summonIconTextPending", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        sumSettings:AddWidget(GUI:CreateEditBox(self.child, L["Accepted Text"], db, "summonIconTextAccepted", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        sumSettings:AddWidget(GUI:CreateEditBox(self.child, L["Declined Text"], db, "summonIconTextDeclined", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        Add(sumSettings, nil, 1)
        summonSection:RegisterChild(sumSettings)

        -- Appearance
        local sumAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "summonIcon:Appearance" })
        sumAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        sumAppearance.disableChildrenOn = function(d) return not d.summonIconEnabled end
        sumAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "summonIconScale", nil, function() DF:LightweightUpdateIconPosition("summon") end, true), 55)
        sumAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "summonIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("summon") end, true), 55)
        sumAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "summonIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("summon") end, true), 55)
        sumAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "summonIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(sumAppearance, nil, 1)
        summonSection:RegisterChild(sumAppearance)

        -- Position
        local sumPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "summonIcon:Position" })
        sumPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        sumPosition.disableChildrenOn = function(d) return not d.summonIconEnabled end
        sumPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "summonIconAnchor", function() DF:LightweightUpdateIconPosition("summon") end), 55)
        sumPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "summonIconX", nil, function() DF:LightweightUpdateIconPosition("summon") end, true), 55)
        sumPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "summonIconY", nil, function() DF:LightweightUpdateIconPosition("summon") end, true), 55)
        Add(sumPosition, nil, 1)
        summonSection:RegisterChild(sumPosition)

        -- ============================================
        -- BG OBJECTIVE CARRIER ICON (Collapsible)
        -- Lights up a unit carrying a battleground objective
        -- (flag / orb). Detection is UnitPvpClassification, so it
        -- works with Blizzard raid frames fully disabled.
        -- ============================================
        local bgCarrierSection = Add(GUI:CreateCollapsibleSection(self.child, L["BG Carrier Icon"], false, 270), 28, 1)
        WireStatusPreview(bgCarrierSection, { enableKey = "bgCarrierIconEnabled", showTextKey = "bgCarrierIconShowText", icons = { "Interface\\Icons\\inv_bannerpvp_02" }, texts = { "bgCarrierIconText" } })

        -- Small gap between the section header and the first box.
        local bgcHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        bgCarrierSection:RegisterChild(bgcHeaderGap)

        -- Settings
        local bgcSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "bgCarrierIcon:Settings" })
        bgcSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        bgcSettings.disableChildrenOn = function(d) return not d.bgCarrierIconEnabled end
        local bgCarrierIconEnableCb = bgcSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable BG Carrier Icon"], db, "bgCarrierIconEnabled", function() DF:UpdateAllFrames() end), 30)
        bgCarrierIconEnableCb.keepEnabled = true
        bgcSettings:AddWidget(GUI:CreateLabel(self.child, L["Shows on a friendly party/raid member carrying a battleground objective (flag, orb). Only active inside battlegrounds."], 240), 44)
        bgcSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "bgCarrierIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        bgcSettings:AddWidget(GUI:CreateEditBox(self.child, L["Carrier Text"], db, "bgCarrierIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        Add(bgcSettings, nil, 1)
        bgCarrierSection:RegisterChild(bgcSettings)

        -- Appearance
        local bgcAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "bgCarrierIcon:Appearance" })
        bgcAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        bgcAppearance.disableChildrenOn = function(d) return not d.bgCarrierIconEnabled end
        bgcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "bgCarrierIconScale", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        bgcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "bgCarrierIconAlpha", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        bgcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "bgCarrierIconFrameLevel", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        Add(bgcAppearance, nil, 1)
        bgCarrierSection:RegisterChild(bgcAppearance)

        -- Position
        local bgcPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "bgCarrierIcon:Position" })
        bgcPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        bgcPosition.disableChildrenOn = function(d) return not d.bgCarrierIconEnabled end
        bgcPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "bgCarrierIconAnchor", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 55)
        bgcPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "bgCarrierIconX", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        bgcPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "bgCarrierIconY", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        Add(bgcPosition, nil, 1)
        bgCarrierSection:RegisterChild(bgcPosition)

        -- ============================================
        -- COMBAT ICON (Collapsible)
        -- ============================================
        local combatSection = Add(GUI:CreateCollapsibleSection(self.child, L["Combat Icon"], false, 270), 28, 1)
        -- Preview the swords quadrant of the UI-StateIcon sheet (texcoord slice); also
        -- greys the section header when the icon is disabled.
        WireStatusPreview(combatSection, { enableKey = "combatIconEnabled", icons = { { texture = "Interface\\CharacterFrame\\UI-StateIcon", coords = {0.5, 1.0, 0, 0.49} } } })

        local combatHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        combatSection:RegisterChild(combatHeaderGap)

        -- Settings
        local combatSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "combatIcon:Settings" })
        combatSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        combatSettings.disableChildrenOn = function(d) return not d.combatIconEnabled end
        local combatIconEnableCb = combatSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Combat Icon"], db, "combatIconEnabled", function() DF:UpdateAllFrames() end), 30)
        combatIconEnableCb.keepEnabled = true
        combatSettings:AddWidget(GUI:CreateLabel(self.child, L["Shows crossed swords on a party/raid member who is in combat."], 240), 44)
        Add(combatSettings, nil, 1)
        combatSection:RegisterChild(combatSettings)

        -- Appearance
        local combatAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "combatIcon:Appearance" })
        combatAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        combatAppearance.disableChildrenOn = function(d) return not d.combatIconEnabled end
        combatAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "combatIconScale", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        combatAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "combatIconAlpha", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        combatAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "combatIconFrameLevel", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        Add(combatAppearance, nil, 1)
        combatSection:RegisterChild(combatAppearance)

        -- Position
        local combatPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "combatIcon:Position" })
        combatPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        combatPosition.disableChildrenOn = function(d) return not d.combatIconEnabled end
        combatPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "combatIconAnchor", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 55)
        combatPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "combatIconX", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        combatPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "combatIconY", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        Add(combatPosition, nil, 1)
        combatSection:RegisterChild(combatPosition)

        -- ============================================
        -- RESURRECTION ICON (Collapsible)
        -- ============================================
        local resSection = Add(GUI:CreateCollapsibleSection(self.child, L["Resurrection Icon"], false, 270), 28, 1)
        WireStatusPreview(resSection, { enableKey = "resurrectionIconEnabled", showTextKey = "resurrectionIconShowText", icons = { "RaidFrame-Icon-Rez" }, texts = { "resurrectionIconTextCasting" } })
        
        -- Small gap between the section header and the first box.
        local resHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        resSection:RegisterChild(resHeaderGap)

        -- Settings
        local resSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "resurrectionIcon:Settings" })
        resSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        resSettings.disableChildrenOn = function(d) return not d.resurrectionIconEnabled end
        local resurrectionIconEnableCb = resSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Resurrection Icon"], db, "resurrectionIconEnabled", function() DF:UpdateAllFrames() end), 30)
        resurrectionIconEnableCb.keepEnabled = true
        resSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "resurrectionIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        resSettings:AddWidget(GUI:CreateEditBox(self.child, L["Casting Text"], db, "resurrectionIconTextCasting", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        resSettings:AddWidget(GUI:CreateEditBox(self.child, L["Pending Text"], db, "resurrectionIconTextPending", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        Add(resSettings, nil, 1)
        resSection:RegisterChild(resSettings)

        -- Appearance
        local resAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "resurrectionIcon:Appearance" })
        resAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        resAppearance.disableChildrenOn = function(d) return not d.resurrectionIconEnabled end
        resAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "resurrectionIconScale", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55)
        resAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "resurrectionIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("resurrection") end, true), 55)
        resAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "resurrectionIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("resurrection") end, true), 55)
        Add(resAppearance, nil, 1)
        resSection:RegisterChild(resAppearance)

        -- Position
        local resPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "resurrectionIcon:Position" })
        resPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        resPosition.disableChildrenOn = function(d) return not d.resurrectionIconEnabled end
        resPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "resurrectionIconAnchor", function() DF:LightweightUpdateIconPosition("resurrection") end), 55)
        resPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "resurrectionIconX", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55)
        resPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "resurrectionIconY", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55)
        Add(resPosition, nil, 1)
        resSection:RegisterChild(resPosition)
        
        -- ============================================
        -- PHASED ICON (Collapsible)
        -- ============================================
        local phasedSection = Add(GUI:CreateCollapsibleSection(self.child, L["Phased Icon"], false, 270), 28, 1)
        WireStatusPreview(phasedSection, { enableKey = "phasedIconEnabled", showTextKey = "phasedIconShowText", icons = { "RaidFrame-Icon-Phasing" }, texts = { "phasedIconText" } })
        
        -- Small gap between the section header and the first box.
        local phHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        phasedSection:RegisterChild(phHeaderGap)

        -- Settings
        local phSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "phasedIcon:Settings" })
        phSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        phSettings.disableChildrenOn = function(d) return not d.phasedIconEnabled end
        local phasedIconEnableCb = phSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Phased Icon"], db, "phasedIconEnabled", function() DF:UpdateAllFrames() end), 30)
        phasedIconEnableCb.keepEnabled = true
        phSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "phasedIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        phSettings:AddWidget(GUI:CreateEditBox(self.child, L["Status Text"], db, "phasedIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        phSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show LFG Eye for Cross-Instance"], db, "phasedIconShowLFGEye", function() DF:UpdateAllFrames() end), 30)
        Add(phSettings, nil, 1)
        phasedSection:RegisterChild(phSettings)

        -- Appearance
        local phAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "phasedIcon:Appearance" })
        phAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        phAppearance.disableChildrenOn = function(d) return not d.phasedIconEnabled end
        phAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "phasedIconScale", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55)
        phAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "phasedIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("phased") end, true), 55)
        phAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "phasedIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("phased") end, true), 55)
        phAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "phasedIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(phAppearance, nil, 1)
        phasedSection:RegisterChild(phAppearance)

        -- Position
        local phPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "phasedIcon:Position" })
        phPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        phPosition.disableChildrenOn = function(d) return not d.phasedIconEnabled end
        phPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "phasedIconAnchor", function() DF:LightweightUpdateIconPosition("phased") end), 55)
        phPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "phasedIconX", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55)
        phPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "phasedIconY", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55)
        Add(phPosition, nil, 1)
        phasedSection:RegisterChild(phPosition)
        
        -- ============================================
        -- AFK ICON (Collapsible)
        -- ============================================
        local afkSection = Add(GUI:CreateCollapsibleSection(self.child, L["AFK Icon"], false, 270), 28, 1)
        WireStatusPreview(afkSection, { enableKey = "afkIconEnabled", showTextKey = "afkIconShowText", icons = { "characterupdate_clock-icon" }, texts = { "afkIconText" } })
        
        -- AFK options split into collapsible boxed sub-groups (Settings / Timer
        -- Text / Appearance / Position), matching the Aura Designer layout. Each
        -- box uses a unique collapseKey so the standard headers don't share
        -- collapse state across icons/pages.
        local afkTimerCB = function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end

        -- Small gap between the section header and the first box.
        local afkHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        afkSection:RegisterChild(afkHeaderGap)

        -- Settings
        local afkSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "afkIcon:Settings" })
        afkSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        afkSettings.disableChildrenOn = function(d) return not d.afkIconEnabled end
        local afkIconEnableCb = afkSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable AFK Icon"], db, "afkIconEnabled", function() DF:UpdateAllFrames() end), 30)
        afkIconEnableCb.keepEnabled = true
        afkSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "afkIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        afkSettings:AddWidget(GUI:CreateEditBox(self.child, L["Status Text"], db, "afkIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        afkSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show Timer"], db, "afkIconShowTimer", function() DF:UpdateAllFramesStatusIcons() end), 30)
        -- In text mode the timer is merged into the status text, so the Timer
        -- Text box is hidden; explain it inherits the main text styling.
        local afkTimerInheritNote = afkSettings:AddWidget(GUI:CreateLabel(self.child, L["In Text mode the timer joins the status text and uses its font, colour and position."], 230), 40)
        afkTimerInheritNote.hideOn = function(d) return not d.afkIconShowText or not d.afkIconShowTimer end
        Add(afkSettings, nil, 1)
        afkSection:RegisterChild(afkSettings)

        -- Timer Text — elapsed-time text under the icon. Icon mode only (Show as
        -- Text off) with Show Timer on, so the whole box is gated.
        local afkTimerGroup = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "afkIcon:TimerText" })
        afkTimerGroup:AddWidget(GUI:CreateHeader(self.child, L["Timer Text"]), 25)
        afkTimerGroup.disableChildrenOn = function(d) return not d.afkIconEnabled end
        afkTimerGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "afkIconTimerFont", afkTimerCB, "statusIconFont"), 55)
        afkTimerGroup:AddWidget(GUI:CreateSlider(self.child, L["Size"], 6, 24, 1, db, "afkIconTimerFontSize", afkTimerCB, afkTimerCB, true), 55)
        afkTimerGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "afkIconTimerOutline", afkTimerCB, "statusIconFontOutline"), 55)
        afkTimerGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "afkIconTimerColor", false, nil, afkTimerCB, true), 30)
        afkTimerGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "afkIconTimerX", afkTimerCB, afkTimerCB, true), 55)
        afkTimerGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "afkIconTimerY", afkTimerCB, afkTimerCB, true), 55)
        Add(afkTimerGroup, nil, 1)
        afkSection:RegisterChild(afkTimerGroup)
        afkTimerGroup.hideOn = function(d) return not d.afkIconShowTimer or d.afkIconShowText end

        -- Appearance
        local afkAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "afkIcon:Appearance" })
        afkAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        afkAppearance.disableChildrenOn = function(d) return not d.afkIconEnabled end
        afkAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "afkIconScale", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55)
        afkAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "afkIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("afk") end, true), 55)
        afkAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "afkIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("afk") end, true), 55)
        afkAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "afkIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(afkAppearance, nil, 1)
        afkSection:RegisterChild(afkAppearance)

        -- Position
        local afkPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "afkIcon:Position" })
        afkPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        afkPosition.disableChildrenOn = function(d) return not d.afkIconEnabled end
        afkPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "afkIconAnchor", function() DF:LightweightUpdateIconPosition("afk") end), 55)
        afkPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "afkIconX", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55)
        afkPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "afkIconY", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55)
        Add(afkPosition, nil, 1)
        afkSection:RegisterChild(afkPosition)
        
        -- ============================================
        -- VEHICLE ICON (Collapsible)
        -- ============================================
        local vehSection = Add(GUI:CreateCollapsibleSection(self.child, L["Vehicle Icon"], false, 270), 28, 1)
        WireStatusPreview(vehSection, { enableKey = "vehicleIconEnabled", showTextKey = "vehicleIconShowText", icons = { "RaidFrame-Icon-Vehicle" }, texts = { "vehicleIconText" } })
        
        -- Small gap between the section header and the first box.
        local vehHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        vehSection:RegisterChild(vehHeaderGap)

        -- Settings
        local vehSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "vehicleIcon:Settings" })
        vehSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        vehSettings.disableChildrenOn = function(d) return not d.vehicleIconEnabled end
        local vehicleIconEnableCb = vehSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Vehicle Icon"], db, "vehicleIconEnabled", function() DF:UpdateAllFrames() end), 30)
        vehicleIconEnableCb.keepEnabled = true
        vehSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "vehicleIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        vehSettings:AddWidget(GUI:CreateEditBox(self.child, L["Status Text"], db, "vehicleIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        Add(vehSettings, nil, 1)
        vehSection:RegisterChild(vehSettings)

        -- Appearance
        local vehAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "vehicleIcon:Appearance" })
        vehAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        vehAppearance.disableChildrenOn = function(d) return not d.vehicleIconEnabled end
        vehAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "vehicleIconScale", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55)
        vehAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "vehicleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("vehicle") end, true), 55)
        vehAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "vehicleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("vehicle") end, true), 55)
        vehAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "vehicleIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(vehAppearance, nil, 1)
        vehSection:RegisterChild(vehAppearance)

        -- Position
        local vehPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "vehicleIcon:Position" })
        vehPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        vehPosition.disableChildrenOn = function(d) return not d.vehicleIconEnabled end
        vehPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "vehicleIconAnchor", function() DF:LightweightUpdateIconPosition("vehicle") end), 55)
        vehPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "vehicleIconX", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55)
        vehPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "vehicleIconY", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55)
        Add(vehPosition, nil, 1)
        vehSection:RegisterChild(vehPosition)
        
        -- ============================================
        -- RAID ROLE ICON (Collapsible)
        -- ============================================
        local rrSection = Add(GUI:CreateCollapsibleSection(self.child, L["Raid Role Icon (MT/MA)"], false, 270), 28, 1)
        WireStatusPreview(rrSection, { enableKey = "raidRoleIconEnabled", showTextKey = "raidRoleIconShowText", icons = { "RaidFrame-Icon-MainTank", "RaidFrame-Icon-MainAssist" }, texts = { "raidRoleIconTextTank", "raidRoleIconTextAssist" } })
        
        -- Small gap between the section header and the first box.
        local rrHeaderGap = Add(CreateFrame("Frame", nil, self.child), 8, 1)
        rrSection:RegisterChild(rrHeaderGap)

        -- Settings
        local rrSettings = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "raidRoleIcon:Settings" })
        rrSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 25)
        rrSettings.disableChildrenOn = function(d) return not d.raidRoleIconEnabled end
        local raidRoleIconEnableCb = rrSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Raid Role Icon"], db, "raidRoleIconEnabled", function() DF:UpdateAllFrames() end), 30)
        raidRoleIconEnableCb.keepEnabled = true
        rrSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show Main Tank"], db, "raidRoleIconShowTank", function() DF:UpdateAllFrames() end), 30)
        rrSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show Main Assist"], db, "raidRoleIconShowAssist", function() DF:UpdateAllFrames() end), 30)
        rrSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "raidRoleIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        rrSettings:AddWidget(GUI:CreateEditBox(self.child, L["Tank Text"], db, "raidRoleIconTextTank", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        rrSettings:AddWidget(GUI:CreateEditBox(self.child, L["Assist Text"], db, "raidRoleIconTextAssist", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        Add(rrSettings, nil, 1)
        rrSection:RegisterChild(rrSettings)

        -- Appearance
        local rrAppearance = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "raidRoleIcon:Appearance" })
        rrAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 25)
        rrAppearance.disableChildrenOn = function(d) return not d.raidRoleIconEnabled end
        rrAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "raidRoleIconScale", nil, function() DF:LightweightUpdateIconPosition("raidRole") end, true), 55)
        rrAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "raidRoleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("raidRole") end, true), 55)
        rrAppearance:AddWidget(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "raidRoleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("raidRole") end, true), 55)
        rrAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "raidRoleIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(rrAppearance, nil, 1)
        rrSection:RegisterChild(rrAppearance)

        -- Position
        local rrPosition = GUI:CreateSettingsGroup(self.child, 270, { collapsible = true, collapseKey = "raidRoleIcon:Position" })
        rrPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 25)
        rrPosition.disableChildrenOn = function(d) return not d.raidRoleIconEnabled end
        rrPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "raidRoleIconAnchor", function() DF:LightweightUpdateIconPosition("raidRole") end), 55)
        rrPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "raidRoleIconX", nil, function() DF:LightweightUpdateIconPosition("raidRole") end, true), 55)
        rrPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "raidRoleIconY", nil, function() DF:LightweightUpdateIconPosition("raidRole") end, true), 55)
        Add(rrPosition, nil, 1)
        rrSection:RegisterChild(rrPosition)
    end)
    
    -- Indicators > Highlights
    local pageHighlights = CreateSubTab("indicators", "indicators_highlights", L["Highlights"])
    BuildPage(pageHighlights, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"selectionHighlight", "hoverHighlight", "aggroHighlight", "aggro"}, L["Highlights"], "indicators_highlights"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local highlightModes = {
            ["NONE"] = L["Hidden"],
            ["SOLID"] = L["Solid Border"],
            ["ANIMATED"] = L["Animated Border"],
            ["DASHED"] = L["Dashed Border"],
            ["GLOW"] = L["Glow"],
            ["CORNERS"] = L["Corners Only"],
        }
        
        -- ========================================
        -- SELECTION HIGHLIGHT SECTION
        -- ========================================
        local selectionSection = Add(GUI:CreateCollapsibleSection(self.child, L["Selection Highlight"], true), 36, "both")
        currentSection = selectionSection
        
        local function HideSelectionOptions(d) return d.selectionHighlightMode == "NONE" end
        
        local selGroup = GUI:CreateSettingsGroup(self.child, 260)
        selGroup:AddWidget(GUI:CreateHeader(self.child, L["Selection Settings"]), 40)
        selGroup:AddWidget(GUI:CreateDropdown(self.child, L["Mode"], highlightModes, db, "selectionHighlightMode", function()
            self:RefreshStates()
        end), 55)
        local selThick = selGroup:AddWidget(GUI:CreateSlider(self.child, L["Thickness"], 1, 10, 1, db, "selectionHighlightThickness", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selThick.hideOn = HideSelectionOptions
        local selInset = selGroup:AddWidget(GUI:CreateSlider(self.child, L["Inset"], -10, 10, 1, db, "selectionHighlightInset", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selInset.hideOn = HideSelectionOptions
        local selAlpha = selGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "selectionHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selAlpha.hideOn = HideSelectionOptions
        local selCol = selGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "selectionHighlightColor", false, nil, function() DF:LightweightUpdateSelectionHighlightColor() end, true), 35)
        selCol.hideOn = HideSelectionOptions
        AddToSection(selGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ========================================
        -- HOVER HIGHLIGHT SECTION
        -- ========================================
        local hoverSection = Add(GUI:CreateCollapsibleSection(self.child, L["Hover Highlight"], true), 36, "both")
        currentSection = hoverSection
        
        local function HideHoverOptions(d) return d.hoverHighlightMode == "NONE" end
        
        local hoverGroup = GUI:CreateSettingsGroup(self.child, 260)
        hoverGroup:AddWidget(GUI:CreateHeader(self.child, L["Hover Settings"]), 40)
        hoverGroup:AddWidget(GUI:CreateDropdown(self.child, L["Mode"], highlightModes, db, "hoverHighlightMode", function()
            self:RefreshStates()
        end), 55)
        local hoverThick = hoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Thickness"], 1, 10, 1, db, "hoverHighlightThickness", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverThick.hideOn = HideHoverOptions
        local hoverInset = hoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Inset"], -10, 10, 1, db, "hoverHighlightInset", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverInset.hideOn = HideHoverOptions
        local hoverAlpha = hoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "hoverHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverAlpha.hideOn = HideHoverOptions
        local hoverCol = hoverGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "hoverHighlightColor", false, nil, function() DF:LightweightUpdateHighlight("hover") end, true), 35)
        hoverCol.hideOn = HideHoverOptions
        AddToSection(hoverGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ========================================
        -- AGGRO HIGHLIGHT SECTION
        -- ========================================
        local aggroSection = Add(GUI:CreateCollapsibleSection(self.child, L["Aggro Highlight"], true), 36, "both")
        currentSection = aggroSection
        
        local function HideAggroOptions(d) return d.aggroHighlightMode == "NONE" or d.aggroHighlightMode == "HEALTH_COLOR" end
        local function HideAggroModeNone(d) return d.aggroHighlightMode == "NONE" end
        local function HideCustomColorOptions(d) return d.aggroHighlightMode == "NONE" or not d.aggroUseCustomColors end
        local function HideNonTankingColors(d) return d.aggroHighlightMode == "NONE" or not d.aggroUseCustomColors or d.aggroOnlyTanking end
        
        local aggroModes = {
            ["NONE"] = L["Hidden"],
            ["HEALTH_COLOR"] = L["Health Bar Color"],
            ["SOLID"] = L["Solid Border"],
            ["ANIMATED"] = L["Animated Border"],
            ["DASHED"] = L["Dashed Border"],
            ["GLOW"] = L["Glow"],
            ["CORNERS"] = L["Corners Only"],
        }
        
        -- Aggro Settings Group (col1)
        local aggroGroup = GUI:CreateSettingsGroup(self.child, 260)
        aggroGroup:AddWidget(GUI:CreateHeader(self.child, L["Aggro Settings"]), 40)
        aggroGroup:AddWidget(GUI:CreateDropdown(self.child, L["Mode"], aggroModes, db, "aggroHighlightMode", function()
            self:RefreshStates()
            if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
        end), 55)
        local aggroOnlyTanking = aggroGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Only Show When Tanking"], db, "aggroOnlyTanking", function()
            self:RefreshStates()
            if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
        end), 28)
        aggroOnlyTanking.hideOn = HideAggroModeNone
        local aggroHideOnTanks = aggroGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide on Tanks"], db, "aggroHideOnTanks", function()
            if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
        end), 28)
        aggroHideOnTanks.hideOn = HideAggroModeNone
        local aggroThick = aggroGroup:AddWidget(GUI:CreateSlider(self.child, L["Thickness"], 1, 10, 1, db, "aggroHighlightThickness", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroThick.hideOn = HideAggroOptions
        local aggroInset = aggroGroup:AddWidget(GUI:CreateSlider(self.child, L["Inset"], -10, 10, 1, db, "aggroHighlightInset", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroInset.hideOn = HideAggroOptions
        local aggroAlpha = aggroGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "aggroHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroAlpha.hideOn = HideAggroOptions
        AddToSection(aggroGroup, nil, 1)
        
        -- Threat Colors Group (col2)
        local threatGroup = GUI:CreateSettingsGroup(self.child, 260)
        threatGroup:AddWidget(GUI:CreateHeader(self.child, L["Threat Colors"]), 40)
        local useCustomColors = threatGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Custom Colors"], db, "aggroUseCustomColors", function()
            self:RefreshStates()
            if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
        end), 28)
        useCustomColors.hideOn = HideAggroModeNone
        local colorHighThreat = threatGroup:AddWidget(GUI:CreateColorPicker(self.child, L["High Threat (Yellow)"], db, "aggroColorHighThreat", false, nil, function()
            DF:LightweightUpdateHighlight("aggro")
        end, true), 30)
        colorHighThreat.hideOn = HideNonTankingColors
        local colorHighestThreat = threatGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Highest Threat (Orange)"], db, "aggroColorHighestThreat", false, nil, function()
            DF:LightweightUpdateHighlight("aggro")
        end, true), 30)
        colorHighestThreat.hideOn = HideNonTankingColors
        local colorTanking = threatGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Tanking (Red)"], db, "aggroColorTanking", false, nil, function()
            DF:LightweightUpdateHighlight("aggro")
        end, true), 30)
        colorTanking.hideOn = HideCustomColorOptions
        threatGroup:AddWidget(GUI:CreateLabel(self.child, L["Yellow=high, Orange=highest, Red=tanking."], 230), 25)
        threatGroup.hideOn = HideAggroModeNone
        AddToSection(threatGroup, nil, 2)
        
        currentSection = nil
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_dispel", label = L["Dispel Overlay"]},
        }), 30, "both")
    end)
    
    -- Auras > Dispel Overlay (moved from Indicators)
    local pageDispel = CreateSubTab("auras", "auras_dispel", L["Dispel Overlay"])
    BuildPage(pageDispel, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"dispel"}, L["Dispel Overlay"], "auras_dispel"), 25, 2)

        AddSpace(10, "both")

        local function HideIfDisabled(d)
            return d.dispelOverlayEnabled == false
        end
        -- Alias kept so the widget wiring below reads unchanged — under the
        -- unified overlay every appearance control simply follows the toggle.
        local HideDispelOptions = HideIfDisabled

        -- 12.1: the container factory owns the overlay — the era frosts below
        -- lift when it does (mirrors the Missing Buffs page's conditional lift).
        local dispelFactoryOwns = DF.FactoryOwnsDispelOverlay and DF:FactoryOwnsDispelOverlay(db)

        -- Every dispel-page callback funnels through here: the version bump
        -- breaks the 12.1 factory drive's fast-path latch, so structural changes
        -- (colour source, me/all, icon slots, bleed opt-in) rebuild their slot
        -- set and pure styling re-applies. Cheap out of combat; no-op impact
        -- pre-12.1 (the legacy path reads settings directly).
        local function ApplyDispelSettings()
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end

        local function InvalidateCurves()
            if DF.InvalidateDispelColorCurve then DF:InvalidateDispelColorCurve() end
            ApplyDispelSettings()
        end

        local function OnDispelTypeChanged()
            InvalidateCurves()
        end

        -- ===== ENABLE + SHARED SETTINGS =====
        -- 12.1 unified overlay: ONE container-slot-driven system (Features/
        -- Dispel.lua factory path) covering normal AND private-aura dispels
        -- natively. The old Off / DandersFrames / Blizzard / Hybrid source
        -- selector collapsed into this single toggle when the Blizzard wrapper
        -- retired (settings migrate: any non-Off source = enabled).
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Dispel Overlay"], db, "dispelOverlayEnabled", function()
            ApplyDispelSettings()
            self:RefreshStates()
            GUI:RefreshCurrentPage()
        end), 30)
        local dispelIndicatorOptions = { [1]= L["Dispellable By Me"], [2]= L["All Dispellable"] }
        local dispelIndicatorDropdown = settingsGroup:AddWidget(GUI:CreateDropdown(self.child, L["Show Overlay For"], dispelIndicatorOptions, db, "dispelOverlayDispelType", function()
            OnDispelTypeChanged()
        end), 55)
        dispelIndicatorDropdown.hideOn = HideIfDisabled
        -- One system: the game's dispel palette via the native tint, one overlay
        -- at a time (Blizzard-identical, covers private auras). The Custom Colors
        -- mode (per-type slots + pickers) was removed 2026-07-11 — its dual-
        -- overlay quirk wasn't worth the confusion once game mode gained the
        -- border and edge glow.
        local overlayNote = settingsGroup:AddWidget(GUI:CreateNote(self.child,
            L["One overlay at a time, colored and switched by the game engine. Includes boss (private) auras."],
            { width = 260 }), 40)
        overlayNote.hideOn = HideIfDisabled
        Add(settingsGroup, nil, 1)

        -- ===== APPEARANCE COLLAPSIBLE SECTION =====
        -- Wraps all overlay-appearance SettingsGroups below. Header hides
        -- entirely when the overlay is off; groups hide via their own hideOn
        -- + the section's collapsed state.
        AddSyncPoint()
        AddSpace(10, "both")
        local dfSection = GUI:CreateCollapsibleSection(self.child, L["Appearance"], true, 560)
        dfSection.hideOn = HideIfDisabled
        Add(dfSection, 36, "both")

        -- Display group (quick toggles) — Column 1
        local displayGroup = GUI:CreateSettingsGroup(self.child, 280)
        displayGroup:AddWidget(GUI:CreateHeader(self.child, L["Display"]), 40)
        -- Show Border / Show Gradient are the master toggles for their features, so
        -- each one now HEADS its own group below (Border / Gradient) — mirroring the
        -- Show Dispel Icon toggle that heads the Icon group. Keeps every group's
        -- on/off switch at the top of that group.
        -- Boolean toggles GREY their dependent controls in place (addon-wide
        -- convention); hideOn stays for the feature/variant switches only.
        local DisableIfNoGradient = function(d) return d.dispelShowGradient == false end
        local DisableIfNoBorder = function(d) return d.dispelShowBorder == false end
        local DisableIfNoIcon = function(d) return d.dispelShowIcon == false end
        local animate = displayGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Pulse Overlay"], db, "dispelAnimate", function()
            ApplyDispelSettings()
        end), 30)
        animate.hideOn = HideDispelOptions
        local nameTextCheck = displayGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Color Name Text"], db, "dispelNameText", function()
            ApplyDispelSettings()
        end), 30)
        nameTextCheck.hideOn = HideDispelOptions
        -- Not yet wired to the 12.1 slot overlay (needs the occlusion-safe name
        -- tint fast-follow) — marked in place even while the factory owns.
        GUI:BlockControl12_1(nameTextCheck, "roadmap", { id = "dispel:nametext", page = L["Dispel Overlay"] })
        displayGroup.hideOn = HideDispelOptions
        dfSection:RegisterChild(displayGroup)
        if not dispelFactoryOwns then GUI:BlockControl12_1(displayGroup, "roadmap", { id = "dispel:display", page = L["Dispel Overlay"] }) end
        Add(displayGroup, nil, 1)

        -- ===== ICON GROUP (Column 2) =====
        local iconGroup = GUI:CreateSettingsGroup(self.child, 280)
        iconGroup:AddWidget(GUI:CreateHeader(self.child, L["Dispel Type Icon"]), 40)
        local showIcon = iconGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Dispel Icon"], db, "dispelShowIcon", function()
            ApplyDispelSettings()
            self:RefreshStates()
        end), 30)
        showIcon.hideOn = HideDispelOptions
        local iconSize = iconGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 10, 40, 1, db, "dispelIconSize", function()
            ApplyDispelSettings()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        iconSize.hideOn = HideDispelOptions
        iconSize.disableOn = DisableIfNoIcon
        local iconAlpha = iconGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Opacity"], 0.1, 1.0, 0.1, db, "dispelIconAlpha", function()
            InvalidateCurves()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        iconAlpha.hideOn = HideDispelOptions
        iconAlpha.disableOn = DisableIfNoIcon
        local iconPositions = {
            ["CENTER"]= L["Center"], ["TOP"]= L["Top"], ["BOTTOM"]= L["Bottom"],
            ["LEFT"]= L["Left"], ["RIGHT"]= L["Right"],
            ["TOPLEFT"]= L["Top Left"], ["TOPRIGHT"]= L["Top Right"],
            ["BOTTOMLEFT"]= L["Bottom Left"], ["BOTTOMRIGHT"]= L["Bottom Right"],
        }
        local iconPos = iconGroup:AddWidget(GUI:CreateDropdown(self.child, L["Icon Position"], iconPositions, db, "dispelIconPosition", function()
            ApplyDispelSettings()
        end), 55)
        iconPos.hideOn = HideDispelOptions
        iconPos.disableOn = DisableIfNoIcon
        local iconOffsetX = iconGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "dispelIconOffsetX", function()
            ApplyDispelSettings()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        iconOffsetX.hideOn = HideDispelOptions
        iconOffsetX.disableOn = DisableIfNoIcon
        local iconOffsetY = iconGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "dispelIconOffsetY", function()
            ApplyDispelSettings()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        iconOffsetY.hideOn = HideDispelOptions
        iconOffsetY.disableOn = DisableIfNoIcon
        iconGroup.hideOn = HideDispelOptions
        dfSection:RegisterChild(iconGroup)
        if not dispelFactoryOwns then GUI:BlockControl12_1(iconGroup, "roadmap", { id = "dispel:icon", page = L["Dispel Overlay"] }) end
        Add(iconGroup, nil, 2)

        -- ===== BORDER GROUP (Column 1) =====
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        local showBorder = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Border"], db, "dispelShowBorder", function()
            ApplyDispelSettings()
            self:RefreshStates()
        end), 30)
        showBorder.hideOn = HideDispelOptions
        local borderSize = borderGroup:AddWidget(GUI:CreateSlider(self.child, L["Border Thickness"], 1, 6, 1, db, "dispelBorderSize", function()
            ApplyDispelSettings()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        borderSize.hideOn = HideDispelOptions
        borderSize.disableOn = DisableIfNoBorder
        local borderInset = borderGroup:AddWidget(GUI:CreateSlider(self.child, L["Border Inset"], -4, 4, 1, db, "dispelBorderInset", function()
            ApplyDispelSettings()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        borderInset.hideOn = HideDispelOptions
        borderInset.disableOn = DisableIfNoBorder
        local borderAlpha = borderGroup:AddWidget(GUI:CreateSlider(self.child, L["Border Opacity"], 0.1, 1.0, 0.1, db, "dispelBorderAlpha", function()
            InvalidateCurves()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        borderAlpha.hideOn = HideDispelOptions
        borderAlpha.disableOn = DisableIfNoBorder
        borderGroup.hideOn = HideDispelOptions   -- works in BOTH modes (game = ring slot)
        dfSection:RegisterChild(borderGroup)
        if not dispelFactoryOwns then GUI:BlockControl12_1(borderGroup, "roadmap", { id = "dispel:border", page = L["Dispel Overlay"] }) end
        Add(borderGroup, nil, 1)

        -- ===== GRADIENT GROUP (Column 1) =====
        local gradientGroup = GUI:CreateSettingsGroup(self.child, 280)
        gradientGroup:AddWidget(GUI:CreateHeader(self.child, L["Gradient"]), 40)
        local showGradient = gradientGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Gradient"], db, "dispelShowGradient", function()
            ApplyDispelSettings()
            self:RefreshStates()
        end), 30)
        showGradient.hideOn = HideDispelOptions
        local gradientStyles = {
            ["FULL"]= L["Full Frame"], ["TOP"]= L["Top Edge"], ["BOTTOM"]= L["Bottom Edge"],
            ["LEFT"]= L["Left Edge"], ["RIGHT"]= L["Right Edge"], ["EDGE"]= L["Edge Glow (All Sides)"],
        }
        local gradStyle = gradientGroup:AddWidget(GUI:CreateDropdown(self.child, L["Gradient Position"], gradientStyles, db, "dispelGradientStyle", function()
            self:RefreshStates()
            ApplyDispelSettings()
        end), 55)
        gradStyle.hideOn = HideDispelOptions
        gradStyle.disableOn = DisableIfNoGradient
        local onHealthCheck = gradientGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show On Current Health Only"], db, "dispelGradientOnCurrentHealth", function()
            ApplyDispelSettings()
        end), 30)
        onHealthCheck.hideOn = function(d) return HideIfDisabled(d) or d.dispelGradientStyle ~= "FULL" end
        onHealthCheck.disableOn = DisableIfNoGradient
        local gradSize = gradientGroup:AddWidget(GUI:CreateSlider(self.child, L["Gradient Size"], 0.1, 1.0, 0.1, db, "dispelGradientSize", function()
            ApplyDispelSettings()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        gradSize.hideOn = HideDispelOptions
        gradSize.disableOn = DisableIfNoGradient
        local gradAlpha = gradientGroup:AddWidget(GUI:CreateSlider(self.child, L["Gradient Opacity"], 0.1, 1.0, 0.1, db, "dispelGradientAlpha", function()
            InvalidateCurves()
        end, function() DF:InvalidateDispelColorCurve(); DF:LightweightUpdateDispelOverlay() end, true), 55)
        gradAlpha.hideOn = HideDispelOptions
        gradAlpha.disableOn = DisableIfNoGradient
        local blendModes = { ["ADD"]= L["Glow (ADD)"], ["BLEND"]= L["Solid (BLEND)"] }
        local blendDropdown = gradientGroup:AddWidget(GUI:CreateDropdown(self.child, L["Blend Mode"], blendModes, db, "dispelGradientBlendMode", function()
            ApplyDispelSettings()
        end), 55)
        blendDropdown.hideOn = HideDispelOptions
        blendDropdown.disableOn = DisableIfNoGradient
        -- Darken effect lives at the bottom of the Gradient group (it only
        -- renders behind the gradient).
        local darkenCheck = gradientGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Darken Behind Gradient"], db, "dispelGradientDarkenEnabled", function()
            self:RefreshStates()
            ApplyDispelSettings()
        end), 30)
        darkenCheck.hideOn = HideDispelOptions
        darkenCheck.disableOn = DisableIfNoGradient
        local darkenAlpha = gradientGroup:AddWidget(GUI:CreateSlider(self.child, L["Darken Amount"], 0.1, 1.0, 0.05, db, "dispelGradientDarkenAlpha", function()
            ApplyDispelSettings()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        -- HIDE when the dispel feature is off (variant); GREY when the boolean
        -- toggles it depends on are off (disabled-in-place).
        darkenAlpha.hideOn = HideIfDisabled
        darkenAlpha.disableOn = function(d)
            return d.dispelShowGradient == false or not d.dispelGradientDarkenEnabled
        end
        gradientGroup.hideOn = HideDispelOptions
        dfSection:RegisterChild(gradientGroup)
        if not dispelFactoryOwns then GUI:BlockControl12_1(gradientGroup, "limitation", { id = "dispel:gradient", page = L["Dispel Overlay"] }) end
        Add(gradientGroup, nil, 1)


        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_debuffs", label = L["Debuffs"]},
            {pageId = "indicators_highlights", label = L["Highlights"]},
        }), 30, "both")
    end)
    
    -- ========================================
    -- CATEGORY: Profiles
    -- ========================================
    CreateCategory("profiles", L["Profiles"])
    
    -- ========================================
    -- Profiles > Auto Layouts (Raid only)
    -- ========================================
    local pageAutoProfiles = CreateSubTab("profiles", "profiles_auto", L["Auto Layouts"])
    BuildPage(pageAutoProfiles, function(self, db, Add, AddSpace)
        if DF.AutoProfilesUI and DF.AutoProfilesUI.BuildPage then
            DF.AutoProfilesUI:BuildPage(GUI, self, db, Add, AddSpace)
        else
            Add(GUI:CreateHeader(self.child, L["Auto Layouts"]), 40, "both")
            Add(GUI:CreateLabel(self.child, L["Auto Layouts module not loaded."], 400), 30, "both")
        end
    end)
    
    -- Profiles > Manage
    local pageManage = CreateSubTab("profiles", "profiles_manage", L["Manage"])
    BuildPage(pageManage, function(self, db, Add, AddSpace, AddSyncPoint)
        local currentProfile = DF:GetCurrentProfile()
        local profiles = DF:GetProfiles()
        
        -- Helper to add to current section (for collapsible sections this pattern won't apply, but we use groups)
        local currentSection = nil
        local function AddToSection(widget, col, colNum)
            widget.layoutCol = colNum or col
            table.insert(self.children, widget)
        end
        
        -- ============================================
        -- COLUMN 1: Profile List & Creation
        -- ============================================
        
        -- Current Profile Info Group
        local currentGroup = GUI:CreateSettingsGroup(self.child, 260)
        currentGroup:AddWidget(GUI:CreateHeader(self.child, L["Current Profile"]), 40)
        currentGroup:AddWidget(GUI:CreateLabel(self.child, "|cff00ff00" .. currentProfile .. "|r", 240), 25)
        AddToSection(currentGroup, nil, 1)
        
        -- Available Profiles Group
        local listGroup = GUI:CreateSettingsGroup(self.child, 260)
        listGroup:AddWidget(GUI:CreateHeader(self.child, L["Available Profiles"]), 40)
        
        -- Create a container frame for profile list with fixed width and max height
        local maxListHeight = 180
        local contentHeight = #profiles * 28 + 10
        local listHeight = math.min(contentHeight, maxListHeight)
        local listContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        listContainer:SetSize(240, listHeight)
        GUI:CreateElementBackdrop(listContainer, { bgColor = {0, 0, 0, 0.3}, borderColor = {0.3, 0.3, 0.3, 1} })
        listGroup:AddWidget(listContainer, listHeight + 5)
        
        -- Create scroll frame for the profile list
        local profileScroll = CreateFrame("ScrollFrame", nil, listContainer, "ScrollFrameTemplate")
        profileScroll:SetPoint("TOPLEFT", 2, -2)
        profileScroll:SetPoint("BOTTOMRIGHT", -22, 2)
        
        GUI.StyleScrollBar(profileScroll)
        if contentHeight <= maxListHeight and profileScroll.ScrollBar then
            profileScroll.ScrollBar:Hide()
            profileScroll:SetPoint("BOTTOMRIGHT", -4, 2)
        end
        
        -- Create scroll child to hold profile buttons
        local profileScrollChild = CreateFrame("Frame", nil, profileScroll)
        profileScrollChild:SetSize(210, contentHeight)
        profileScroll:SetScrollChild(profileScrollChild)
        
        -- Profile buttons inside scroll child
        local py = -3
        for i, p in ipairs(profiles) do
            local btn = CreateFrame("Button", nil, profileScrollChild, "BackdropTemplate")
            btn:SetSize(206, 24)
            btn:SetPoint("TOPLEFT", 2, py)
            btn:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
            btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            
            local text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            text:SetPoint("CENTER")
            text:SetText(p)
            
            if p == currentProfile then
                local c = GUI.GetThemeColor()
                btn:SetBackdropColor(c.r * 0.3, c.g * 0.3, c.b * 0.3, 1)
                btn:SetBackdropBorderColor(c.r, c.g, c.b, 1)
            end
            
            btn:SetScript("OnEnter", function(self)
                self:SetBackdropColor(0.25, 0.25, 0.25, 1)
            end)
            btn:SetScript("OnLeave", function(self)
                if p == currentProfile then
                    local c = GUI.GetThemeColor()
                    self:SetBackdropColor(c.r * 0.3, c.g * 0.3, c.b * 0.3, 1)
                else
                    self:SetBackdropColor(0.15, 0.15, 0.15, 1)
                end
            end)
            btn:SetScript("OnClick", function() 
                DF:SetProfile(p) 
                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            end)
            py = py - 28
        end
        
        AddToSection(listGroup, nil, 1)
        
        -- Create New Profile Group
        local createGroup = GUI:CreateSettingsGroup(self.child, 260)
        createGroup:AddWidget(GUI:CreateHeader(self.child, L["Create New Profile"]), 40)
        
        local input = GUI:CreateInput(self.child, L["Profile Name"], 240)
        createGroup:AddWidget(input, 50)
        
        -- Button row for create actions
        local btnRow = CreateFrame("Frame", nil, self.child)
        btnRow:SetSize(240, 28)
        
        local createBtn = GUI:CreateButton(self.child, L["Create Empty"], 115, 24, function()
            local text = input.EditBox:GetText()
            if not text or text == "" then
                print("|cffff6666DandersFrames:|r Please enter a profile name.")
                return
            end
            DF:SetProfile(text) 
            input.EditBox:SetText("")
            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
        end)
        createBtn:SetParent(btnRow)
        createBtn:SetPoint("LEFT", 0, 0)
        
        local dupeBtn = GUI:CreateButton(self.child, L["Duplicate Current"], 115, 24, function()
            local text = input.EditBox:GetText()
            if not text or text == "" then
                print("|cffff6666DandersFrames:|r Please enter a name for the duplicated profile.")
                return
            end
            if DF:DuplicateProfile(text) then
                input.EditBox:SetText("")
                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            end
        end)
        dupeBtn:SetParent(btnRow)
        dupeBtn:SetPoint("LEFT", createBtn, "RIGHT", 10, 0)
        
        createGroup:AddWidget(btnRow, 32)
        AddToSection(createGroup, nil, 1)
        
        -- ============================================
        -- COLUMN 2: Actions & Settings
        -- ============================================
        
        -- Profile Actions Group
        local actionsGroup = GUI:CreateSettingsGroup(self.child, 260)
        actionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Profile Actions"]), 40)
        
        -- Register delete confirmation popup
        if not StaticPopupDialogs["DANDERSFRAMES_DELETE_PROFILE_CONFIRM"] then
            StaticPopupDialogs["DANDERSFRAMES_DELETE_PROFILE_CONFIRM"] = {
                text = L["Delete profile '%s'?\n\nThis cannot be undone."],
                button1 = L["Delete"],
                button2 = L["Cancel"],
                OnAccept = function(self, data)
                    DF:SetProfile("Default")
                    DF:DeleteProfile(data)
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
        end
        
        actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "delete", L["Delete Current Profile"], 240, 26, function()
            local p = DF:GetCurrentProfile()
            if p == "Default" then 
                print("|cffff6666DandersFrames:|r Cannot delete Default profile.") 
            else
                local dialog = StaticPopup_Show("DANDERSFRAMES_DELETE_PROFILE_CONFIRM", p)
                if dialog then
                    dialog.data = p
                end
            end
        end, nil, "left"), 32)
        
        -- Register reset confirmation popup
        if not StaticPopupDialogs["DANDERSFRAMES_RESET_PROFILE_CONFIRM"] then
            StaticPopupDialogs["DANDERSFRAMES_RESET_PROFILE_CONFIRM"] = {
                text = L["Reset current profile to defaults?\nThis will reset BOTH Party and Raid settings."],
                button1 = L["Yes"],
                button2 = L["No"],
                OnAccept = function()
                    DF:ResetProfile("party")
                    DF:ResetProfile("raid")
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
        end
        
        actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "refresh", L["Reset Profile to Defaults"], 240, 26, function()
            StaticPopup_Show("DANDERSFRAMES_RESET_PROFILE_CONFIRM")
        end, nil, "left"), 32)
        
        AddToSection(actionsGroup, nil, 2)
        
        -- Copy Settings Group
        local copyGroup = GUI:CreateSettingsGroup(self.child, 260)
        copyGroup:AddWidget(GUI:CreateHeader(self.child, L["Copy Settings"]), 40)
        copyGroup:AddWidget(GUI:CreateLabel(self.child, L["Copy all settings between Party and Raid modes."], 240), 25)
        
        -- Register copy confirmation popups
        if not StaticPopupDialogs["DANDERSFRAMES_COPY_PARTY_TO_RAID"] then
            StaticPopupDialogs["DANDERSFRAMES_COPY_PARTY_TO_RAID"] = {
                text = L["Copy Party settings to Raid?\n\nThis will overwrite all Raid settings with your current Party settings."],
                button1 = L["Copy"],
                button2 = L["Cancel"],
                OnAccept = function()
                    DF:CopyProfile("party", "raid")
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
        end
        
        if not StaticPopupDialogs["DANDERSFRAMES_COPY_RAID_TO_PARTY"] then
            StaticPopupDialogs["DANDERSFRAMES_COPY_RAID_TO_PARTY"] = {
                text = L["Copy Raid settings to Party?\n\nThis will overwrite all Party settings with your current Raid settings."],
                button1 = L["Copy"],
                button2 = L["Cancel"],
                OnAccept = function()
                    DF:CopyProfile("raid", "party")
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
        end
        
        copyGroup:AddWidget(GUI:CreateIconButton(self.child, "chevron_right", L["Party to Raid"], 240, 26, function()
            StaticPopup_Show("DANDERSFRAMES_COPY_PARTY_TO_RAID")
        end, nil, "left"), 32)
        
        copyGroup:AddWidget(GUI:CreateIconButton(self.child, "chevron_right", L["Raid to Party"], 240, 26, function()
            StaticPopup_Show("DANDERSFRAMES_COPY_RAID_TO_PARTY")
        end, nil, "left"), 32)
        
        AddToSection(copyGroup, nil, 2)
        
        -- Auto-Switch by Spec Group
        local specGroup = GUI:CreateSettingsGroup(self.child, 260)
        specGroup:AddWidget(GUI:CreateHeader(self.child, L["Auto-Switch by Spec"]), 40)
        
        -- Initialize per-character data if needed
        if not DandersFramesCharDB then 
            DandersFramesCharDB = { enableSpecSwitch = false, specProfiles = {} } 
        end
        
        local specEnableCb = specGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Spec Auto-Switch"], DandersFramesCharDB, "enableSpecSwitch"), 30)
        specEnableCb.keepEnabled = true
        -- The enable flag lives on the per-character DB (not the page db arg), so
        -- the grey predicate reads DandersFramesCharDB directly.
        specGroup.disableChildrenOn = function() return not (DandersFramesCharDB and DandersFramesCharDB.enableSpecSwitch) end

        local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
        if numSpecs > 0 then
            -- Build profile list for dropdown
            local pList = { [""]= L["None"] }
            for _, p in ipairs(profiles) do 
                pList[p] = p 
            end
            
            if not DandersFramesCharDB.specProfiles then 
                DandersFramesCharDB.specProfiles = {} 
            end
            
            for i = 1, numSpecs do
                local _, name = GetSpecializationInfo(i)
                if name then
                    local specIdx = i  -- capture for the get/set closures
                    -- Custom get/set: an unset spec reads back as "" so it displays
                    -- the "None" option instead of the raw nil ("nil") value. None is
                    -- stored as nil to keep the DB tidy; CheckProfileAutoSwitch treats
                    -- both nil and "" as "don't switch".
                    specGroup:AddWidget(GUI:CreateDropdown(self.child, name, pList, nil, nil, nil,
                        function() return DandersFramesCharDB.specProfiles[specIdx] or "" end,
                        function(v) DandersFramesCharDB.specProfiles[specIdx] = (v ~= "" and v) or nil end), 55)
                end
            end
        else
            specGroup:AddWidget(GUI:CreateLabel(self.child, L["Specialization data not available."], 240), 25)
        end
        
        AddToSection(specGroup, nil, 2)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "profiles_importexport", label = L["Import/Export"]},
        }), 30, "both")
    end)
    
    -- Profiles > Import/Export
    local pageImportExport = CreateSubTab("profiles", "profiles_importexport", L["Import/Export"])
    BuildPage(pageImportExport, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Store references
        self.exportCheckboxes = {}
        self.importCheckboxes = {}
        self.exportFrameTypes = {party = true, raid = true}
        self.importFrameTypes = {party = true, raid = true}
        
        -- Derived from the category registry (single source of truth) so this list
        -- can never drift from DF.ExportCategories when categories change.
        local categoryOrder = {}
        for cat in pairs(DF.ExportCategoryInfo) do table.insert(categoryOrder, cat) end
        table.sort(categoryOrder, function(a, b)
            return (DF.ExportCategoryInfo[a].order or 99) < (DF.ExportCategoryInfo[b].order or 99)
        end)

        -- Page-scope note: unlike the rest of the settings window, this page is
        -- NOT scoped by the party/raid tab -- exports and imports operate on the
        -- whole profile, gated only by the Export for / Import for rows.
        local scopeBanner = GUI:CreateInfoBanner(self.child, {
            tone = "info",
            text = L["Profiles include both Party and Raid settings. Exporting and importing always works on the profile as a whole, no matter which mode tab is selected above. Use the 'Export for' and 'Import for' checkboxes in each column to choose which mode's settings are included."],
        })
        Add(scopeBanner, scopeBanner.layoutHeight or 44, "both")

        -- Helper to add to section
        local function AddToSection(widget, col, colNum)
            widget.layoutCol = colNum or col
            table.insert(self.children, widget)
        end
        
        -- Helper to create themed small checkbox
        local function CreateSmallCheckbox(parent, label, initialChecked)
            local container = CreateFrame("Frame", nil, parent)
            container:SetSize(100, 18)
            
            local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
            cb:SetPoint("LEFT", 0, 0)
            GUI:StyleCheckButton(cb, { size = 14, checkSize = 8, themeRoot = parent })
            
            local txt = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            txt:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            txt:SetText(label)
            txt:SetTextColor(0.85, 0.85, 0.85)
            cb.label = txt
            
            cb:SetChecked(initialChecked or false)
            
            container.checkbox = cb
            container.SetChecked = function(self, val) cb:SetChecked(val) end
            container.GetChecked = function(self) return cb:GetChecked() end
            container.Enable = function(self) cb:Enable(); container:SetAlpha(1) end
            container.Disable = function(self) cb:Disable(); container:SetAlpha(0.35) end
            
            return container
        end
        
        -- Helper to create small themed button
        local function CreateSmallButton(parent, text, width)
            local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            GUI:StyleButton(btn, { width = width, height = 20, text = text })
            btn.text = btn.Text
            return btn
        end
        
        -- ========================================
        -- COLUMN 1: EXPORT
        -- ========================================
        
        -- Export Settings Group
        local exportSettingsGroup = GUI:CreateSettingsGroup(self.child, 260)
        exportSettingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Export Settings"]), 40)
        
        -- Profile name input
        local nameInput = GUI:CreateInput(self.child, L["Profile Name"], 240)
        local currentProfileName = (DF.db and DF.db.keys and DF.db.keys.profile) or "My Profile"
        nameInput.EditBox:SetText(currentProfileName)
        self.exportNameEdit = nameInput.EditBox
        exportSettingsGroup:AddWidget(nameInput, 50)
        
        -- Preset buttons row
        local presetRow = CreateFrame("Frame", nil, self.child)
        presetRow:SetSize(240, 24)
        
        -- frameTypes: true = All checks Party+Raid, false = None clears them,
        -- nil = Look/Layout leave the frame-type row alone.
        local presets = {
            {name = "All", x = 0, frameTypes = true, cats = categoryOrder},
            {name = "Look", x = 60, cats = {"bars", "auras", "dispel", "bossDebuffs", "missingBuffs", "defensives", "myBuffs", "targetedSpells", "targetedList", "text", "textDesigner", "icons", "other"}},
            {name = "Layout", x = 120, cats = {"position", "layout"}},
            {name = "None", x = 180, frameTypes = false, cats = {}},
        }
        
        for _, p in ipairs(presets) do
            local btn = CreateSmallButton(presetRow, L[p.name], 56)
            btn:SetPoint("LEFT", p.x, 0)
            btn:SetScript("OnClick", function()
                local sel = {}
                for _, c in ipairs(p.cats) do sel[c] = true end
                for cat, cb in pairs(self.exportCheckboxes) do cb:SetChecked(sel[cat] or false) end
                -- All/None also drive the Party/Raid row -- keep the STATE table in
                -- sync (SetChecked does not fire the checkbox OnClick handlers).
                if p.frameTypes ~= nil and self.exportFrameTypeBoxes then
                    for ft, box in pairs(self.exportFrameTypeBoxes) do
                        box:SetChecked(p.frameTypes)
                        self.exportFrameTypes[ft] = p.frameTypes
                    end
                    if self.UpdateExportCategoryState then self.UpdateExportCategoryState() end
                end
            end)
        end
        exportSettingsGroup:AddWidget(presetRow, 28)
        
        -- Frame types row ("Export for" -- the modes whose settings ship; the
        -- category list below picks WHICH settings, this row picks WHOSE)
        exportSettingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Export for"], 240), 22)
        local ftRow = CreateFrame("Frame", nil, self.child)
        ftRow:SetSize(240, 20)
        
        local partyExp = CreateSmallCheckbox(ftRow, L["Party"], true)
        partyExp:SetPoint("LEFT", 0, 0)
        partyExp.checkbox:SetScript("OnClick", function(s)
            self.exportFrameTypes.party = s:GetChecked()
            if self.UpdateExportCategoryState then self.UpdateExportCategoryState() end
        end)
        
        local raidExp = CreateSmallCheckbox(ftRow, L["Raid"], true)
        raidExp:SetPoint("LEFT", 80, 0)
        raidExp.checkbox:SetScript("OnClick", function(s)
            self.exportFrameTypes.raid = s:GetChecked()
            if self.UpdateExportCategoryState then self.UpdateExportCategoryState() end
        end)
        self.exportFrameTypeBoxes = {party = partyExp, raid = raidExp}
        exportSettingsGroup:AddWidget(ftRow, 24)
        
        -- Categories ("Settings to include" -- sub-settings of the modes above)
        exportSettingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Settings to include"], 240), 22)
        for _, cat in ipairs(categoryOrder) do
            local info = DF.ExportCategoryInfo[cat]
            local catRow = CreateFrame("Frame", nil, self.child)
            catRow:SetSize(240, 18)
            
            local cb = CreateSmallCheckbox(catRow, L[info.name], true)
            cb:SetPoint("LEFT", 0, 0)
            self.exportCheckboxes[cat] = cb
            exportSettingsGroup:AddWidget(catRow, 20)
        end
        
        -- Grey the category list while no mode is selected (nothing would
        -- export) -- the addon-wide disabled-means-dimmed convention.
        self.UpdateExportCategoryState = function()
            local enabled = self.exportFrameTypes.party or self.exportFrameTypes.raid
            for _, cb in pairs(self.exportCheckboxes) do
                if enabled then cb:Enable() else cb:Disable() end
            end
        end

        AddToSection(exportSettingsGroup, nil, 1)
        
        -- Export Actions Group
        local exportActionsGroup = GUI:CreateSettingsGroup(self.child, 260)
        exportActionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Export"]), 40)
        
        -- Export button
        exportActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "upload", L["Generate Export String"], 240, 26, function()
            local selectedCats = {}
            local allSelected = true
            for _, cat in ipairs(categoryOrder) do
                if self.exportCheckboxes[cat]:GetChecked() then
                    table.insert(selectedCats, cat)
                else
                    allSelected = false
                end
            end
            if allSelected then selectedCats = nil end
            
            local profileName = self.exportNameEdit:GetText()
            if profileName == "" then profileName = nil end
            
            local str = DF:ExportProfile(selectedCats, self.exportFrameTypes, profileName)
            if str and self.exportEditBox then
                self.exportEditBox:SetText(str)
                self.exportEditBox:HighlightText()
                self.exportEditBox:SetFocus()
                print("|cff00ff00DandersFrames:|r Export generated.")
            elseif not str then
                print("|cffff0000DandersFrames:|r Export failed - no string returned")
            end
        end), 32)
        
        -- Export text area
        local exportScrollContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        exportScrollContainer:SetSize(240, 100)
        GUI:CreateElementBackdrop(exportScrollContainer, {
            bgColor = {0.08, 0.08, 0.08, 0.9},
            borderColor = {0.25, 0.25, 0.25, 1},
        })
        
        local exportScroll = CreateFrame("ScrollFrame", nil, exportScrollContainer, "ScrollFrameTemplate")
        exportScroll:SetPoint("TOPLEFT", 4, -4)
        exportScroll:SetPoint("BOTTOMRIGHT", -22, 4)
        GUI.StyleScrollBar(exportScroll)
        
        local exportEditBox = CreateFrame("EditBox", nil, exportScroll)
        exportEditBox:SetMultiLine(true)
        exportEditBox:SetFontObject(DFFontHighlightSmall)
        exportEditBox:SetWidth(210)
        exportEditBox:SetHeight(90)
        exportEditBox:SetAutoFocus(false)
        exportEditBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        exportScroll:SetScrollChild(exportEditBox)
        self.exportEditBox = exportEditBox
        
        exportScrollContainer:EnableMouse(true)
        exportScrollContainer:SetScript("OnMouseDown", function() exportEditBox:SetFocus() end)
        exportScroll:EnableMouse(true)
        exportScroll:SetScript("OnMouseDown", function() exportEditBox:SetFocus() end)
        
        exportActionsGroup:AddWidget(exportScrollContainer, 105)
        
        -- Select All button
        exportActionsGroup:AddWidget(GUI:CreateButton(self.child, L["Select All Text"], 240, 24, function()
            if self.exportEditBox then 
                self.exportEditBox:HighlightText()
                self.exportEditBox:SetFocus()
            end
        end), 28)
        
        AddToSection(exportActionsGroup, nil, 1)
        
        -- ========================================
        -- COLUMN 2: IMPORT
        -- ========================================
        
        -- Import String Group
        local importStringGroup = GUI:CreateSettingsGroup(self.child, 260)
        importStringGroup:AddWidget(GUI:CreateHeader(self.child, L["Import String"]), 40)
        
        -- Import text area
        local importScrollContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        importScrollContainer:SetSize(240, 80)
        GUI:CreateElementBackdrop(importScrollContainer, {
            bgColor = {0.08, 0.08, 0.08, 0.9},
            borderColor = {0.25, 0.25, 0.25, 1},
        })
        
        local importScroll = CreateFrame("ScrollFrame", nil, importScrollContainer, "ScrollFrameTemplate")
        importScroll:SetPoint("TOPLEFT", 4, -4)
        importScroll:SetPoint("BOTTOMRIGHT", -22, 4)
        GUI.StyleScrollBar(importScroll)
        
        local importEditBox = CreateFrame("EditBox", nil, importScroll)
        importEditBox:SetMultiLine(true)
        importEditBox:SetFontObject(DFFontHighlightSmall)
        importEditBox:SetWidth(210)
        importEditBox:SetHeight(70)
        importEditBox:SetAutoFocus(false)
        importEditBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        importScroll:SetScrollChild(importEditBox)
        self.importEditBox = importEditBox
        
        importScrollContainer:EnableMouse(true)
        importScrollContainer:SetScript("OnMouseDown", function() importEditBox:SetFocus() end)
        importScroll:EnableMouse(true)
        importScroll:SetScript("OnMouseDown", function() importEditBox:SetFocus() end)
        
        importStringGroup:AddWidget(importScrollContainer, 85)
        
        -- Parse button
        importStringGroup:AddWidget(GUI:CreateButton(self.child, L["Parse String"], 240, 26, function()
            if not self.importEditBox then return end
            local str = self.importEditBox:GetText()
            if not str or str == "" then
                print("|cffff6666DandersFrames:|r Paste a string first.")
                return
            end
            
            local importData, errMsg = DF:ValidateImportString(str)
            if not importData then
                print("|cffff0000DandersFrames:|r " .. errMsg)
                if self.importInfoLabel then self.importInfoLabel:SetText("|cffff6666Error: " .. errMsg .. "|r") end
                return
            end
            
            self.parsedImportData = importData
            local info = DF:GetImportInfo(importData)
            
            if self.importInfoLabel then
                self.importInfoLabel:SetText(string.format("|cff00ff00" .. L["OK"] .. "|r v%s %s%s",
                    tostring(info.version),
                    info.hasParty and L["[Party]"] or "",
                    info.hasRaid and L["[Raid]"] or ""))
            end
            
            if self.importNameEdit and info.profileName then
                self.importNameEdit:SetText(info.profileName)
            end
            
            if self.createNewProfileCheck then
                self.createNewProfileCheck:Enable()
                self.createNewProfileCheck:SetChecked(true)
            end
            
            local availableCats = {}
            for _, cat in ipairs(info.detectedCategories) do availableCats[cat] = true end
            
            for cat, cb in pairs(self.importCheckboxes) do
                if availableCats[cat] then cb:Enable(); cb:SetChecked(true)
                else cb:Disable(); cb:SetChecked(false) end
            end
            
            if self.importPartyCheck then
                if info.hasParty then self.importPartyCheck:Enable() else self.importPartyCheck:Disable() end
                self.importPartyCheck:SetChecked(info.hasParty)
            end
            if self.importRaidCheck then
                if info.hasRaid then self.importRaidCheck:Enable() else self.importRaidCheck:Disable() end
                self.importRaidCheck:SetChecked(info.hasRaid)
            end
            
            print("|cff00ff00DandersFrames:|r Parsed. Select options and Import.")
        end), 30)
        
        -- Info label
        local infoLabel = self.child:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        infoLabel:SetWidth(240)
        infoLabel:SetJustifyH("LEFT")
        infoLabel:SetText("|cff888888" .. L["Paste string above, then Parse"] .. "|r")
        self.importInfoLabel = infoLabel
        
        local infoContainer = CreateFrame("Frame", nil, self.child)
        infoContainer:SetSize(240, 18)
        infoLabel:SetParent(infoContainer)
        infoLabel:SetPoint("LEFT", 0, 0)
        importStringGroup:AddWidget(infoContainer, 22)
        
        AddToSection(importStringGroup, nil, 2)
        
        -- Import Settings Group
        local importSettingsGroup = GUI:CreateSettingsGroup(self.child, 260)
        importSettingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Import Settings"]), 40)
        
        -- Profile name input for import
        local impNameInput = GUI:CreateInput(self.child, L["Profile Name"], 240)
        impNameInput.EditBox:SetText(L["Imported Profile"])
        self.importNameEdit = impNameInput.EditBox
        importSettingsGroup:AddWidget(impNameInput, 50)
        
        -- Create new profile checkbox
        local createNewRow = CreateFrame("Frame", nil, self.child)
        createNewRow:SetSize(240, 20)
        
        local createNewCheck = CreateSmallCheckbox(createNewRow, L["Create New Profile"], true)
        createNewCheck:SetPoint("LEFT", 0, 0)
        createNewCheck:Disable()
        self.createNewProfileCheck = createNewCheck
        importSettingsGroup:AddWidget(createNewRow, 24)
        
        -- Frame types row ("Import for" -- which mode receives the settings)
        importSettingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Import for"], 240), 22)
        local ftRowImp = CreateFrame("Frame", nil, self.child)
        ftRowImp:SetSize(240, 20)
        
        local partyImp = CreateSmallCheckbox(ftRowImp, L["Party"], false)
        partyImp:SetPoint("LEFT", 0, 0)
        partyImp:Disable()
        partyImp.checkbox:SetScript("OnClick", function(s) self.importFrameTypes.party = s:GetChecked() end)
        self.importPartyCheck = partyImp
        
        local raidImp = CreateSmallCheckbox(ftRowImp, L["Raid"], false)
        raidImp:SetPoint("LEFT", 80, 0)
        raidImp:Disable()
        raidImp.checkbox:SetScript("OnClick", function(s) self.importFrameTypes.raid = s:GetChecked() end)
        self.importRaidCheck = raidImp
        importSettingsGroup:AddWidget(ftRowImp, 24)
        
        -- Categories ("Settings to include")
        importSettingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Settings to include"], 240), 22)
        for _, cat in ipairs(categoryOrder) do
            local info = DF.ExportCategoryInfo[cat]
            local catRow = CreateFrame("Frame", nil, self.child)
            catRow:SetSize(240, 18)
            
            local cb = CreateSmallCheckbox(catRow, L[info.name], false)
            cb:SetPoint("LEFT", 0, 0)
            cb:Disable()
            self.importCheckboxes[cat] = cb
            importSettingsGroup:AddWidget(catRow, 20)
        end
        
        AddToSection(importSettingsGroup, nil, 2)
        
        -- Import Actions Group
        local importActionsGroup = GUI:CreateSettingsGroup(self.child, 260)
        importActionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Import"]), 40)
        
        -- Import button
        importActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "download", L["Import Selected"], 240, 26, function()
            if not self.parsedImportData then
                print("|cffff6666DandersFrames:|r Parse a string first.")
                return
            end
            
            local selectedCats = {}
            for _, cat in ipairs(categoryOrder) do
                if self.importCheckboxes[cat]:GetChecked() then
                    table.insert(selectedCats, cat)
                end
            end
            
            if #selectedCats == 0 then
                print("|cffff6666DandersFrames:|r Select at least one category.")
                return
            end
            
            local selectedFrameTypes = {
                party = self.importPartyCheck:GetChecked(),
                raid = self.importRaidCheck:GetChecked(),
            }
            
            if not selectedFrameTypes.party and not selectedFrameTypes.raid then
                print("|cffff6666DandersFrames:|r Select Party or Raid.")
                return
            end
            
            local createNew = self.createNewProfileCheck and self.createNewProfileCheck:GetChecked()
            local profileName = self.importNameEdit and self.importNameEdit:GetText()
            if profileName == "" then profileName = nil end
            
            local confirmText
            if createNew then
                confirmText = L["Create new profile '"] .. (profileName or L["Imported Profile"]) .. L["'?\n\nThis will copy your current settings, then apply the selected import categories on top."]
            else
                local currentProfile = DF:GetCurrentProfile() or "Default"
                confirmText = L["Import settings into current profile?\n\n"] .. "|c" .. GUI:ToneHex("danger") .. L["WARNING: This will permanently overwrite settings in your '"] .. currentProfile .. L["' profile."] .. "|r\n\n" .. L["Tip: Check 'Create New Profile' to import without affecting your current settings."]
            end
            
            StaticPopupDialogs["DANDERSFRAMES_IMPORT_CONFIRM"] = {
                text = confirmText,
                button1 = L["Import"],
                button2 = L["Cancel"],
                OnAccept = function(dialog)
                    local data = dialog.data
                    if data and data.importData then
                        DF:ApplyImportedProfile(data.importData, data.selectedCats, data.selectedFrameTypes, data.profileName, data.createNew)
                        if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                    end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
            
            local dialog = StaticPopup_Show("DANDERSFRAMES_IMPORT_CONFIRM")
            if dialog then
                dialog.data = {
                    importData = self.parsedImportData,
                    selectedCats = selectedCats,
                    selectedFrameTypes = selectedFrameTypes,
                    profileName = profileName,
                    createNew = createNew,
                }
            end
        end), 32)
        
        -- Clear button
        importActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "close", L["Clear"], 240, 24, function()
            if self.importEditBox then self.importEditBox:SetText("") end
            if self.importInfoLabel then self.importInfoLabel:SetText("|cff888888" .. L["Paste string above, then Parse"] .. "|r") end
            if self.importNameEdit then self.importNameEdit:SetText(L["Imported Profile"]) end
            if self.createNewProfileCheck then self.createNewProfileCheck:Disable(); self.createNewProfileCheck:SetChecked(true) end
            for _, cb in pairs(self.importCheckboxes) do cb:SetChecked(false); cb:Disable() end
            if self.importPartyCheck then self.importPartyCheck:Disable(); self.importPartyCheck:SetChecked(false) end
            if self.importRaidCheck then self.importRaidCheck:Disable(); self.importRaidCheck:SetChecked(false) end
            self.parsedImportData = nil
        end), 28)
        
        AddToSection(importActionsGroup, nil, 2)
        
        -- See Also
        AddSpace(15, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "profiles_manage", label = L["Manage Profiles"]},
        }), 30, "both")
    end)

    -- ========================================
    -- CATEGORY: Wizards
    -- ========================================
    -- Wizards category hidden for now (builder still in development)
    -- CreateCategory("wizards", "Wizards")

    -- Wizards > Setup Wizards (launcher/manager page) — disabled while category is hidden
    if false then
    local pageWizards = CreateSubTab("wizards", "wizards_main", L["Setup Wizards"])
    BuildPage(pageWizards, function(self, db, Add, AddSpace, AddSyncPoint)
        -- ============ BUILT-IN WIZARDS ============
        Add(GUI:CreateHeader(self.child, L["Built-in Wizards"]), 40, "both")

        -- Built-in wizard registry
        local builtins = DF.WizardBuilder and DF.WizardBuilder.GetBuiltinWizards and DF.WizardBuilder:GetBuiltinWizards() or {}

        if #builtins == 0 then
            Add(GUI:CreateLabel(self.child, L["No built-in wizards available yet. Check back after updates!"], 460), 24, "both")
        else
            for _, entry in ipairs(builtins) do
                local row = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
                row:SetSize(460, 50)
                if not row.SetBackdrop then Mixin(row, BackdropTemplateMixin) end
                row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
                row:SetBackdropColor(0.14, 0.14, 0.14, 1)
                row:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.5)

                local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontNormal")
                nameText:SetPoint("TOPLEFT", 12, -8)
                nameText:SetText(entry.name)
                nameText:SetTextColor(0.9, 0.9, 0.9)

                local descText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                descText:SetPoint("TOPLEFT", 12, -24)
                descText:SetPoint("RIGHT", row, "RIGHT", -90, 0)
                descText:SetText(entry.description or "")
                descText:SetTextColor(0.6, 0.6, 0.6)
                descText:SetJustifyH("LEFT")

                local runBtn = GUI:CreateButton(row, L["Run"], 70, 28, function()
                    if entry.build then
                        local config = entry.build()
                        if config then DF:ShowPopupWizard(config) end
                    end
                end)
                runBtn:SetPoint("RIGHT", -8, 0)

                Add(row, 54, "both")
            end
        end

        AddSpace(16, "both")

        -- ============ MY WIZARDS ============
        Add(GUI:CreateHeader(self.child, L["My Wizards"]), 40, "both")

        local configs = DandersFramesDB_v2 and DandersFramesDB_v2.wizardConfigs or {}
        local sortedNames = {}
        for name in pairs(configs) do
            tinsert(sortedNames, name)
        end
        table.sort(sortedNames)

        if #sortedNames == 0 then
            Add(GUI:CreateLabel(self.child, L["No custom wizards yet. Click 'New Wizard' to create one!"], 460), 24, "both")
        else
            for _, name in ipairs(sortedNames) do
                local config = configs[name]
                local row = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
                row:SetSize(460, 50)
                if not row.SetBackdrop then Mixin(row, BackdropTemplateMixin) end
                row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
                row:SetBackdropColor(0.14, 0.14, 0.14, 1)
                row:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.5)

                local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontNormal")
                nameText:SetPoint("TOPLEFT", 12, -8)
                nameText:SetText(config.title or name)
                nameText:SetTextColor(0.9, 0.9, 0.9)

                local descText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                descText:SetPoint("TOPLEFT", 12, -24)
                descText:SetPoint("RIGHT", row, "RIGHT", -240, 0)
                descText:SetText(config.description or "")
                descText:SetTextColor(0.6, 0.6, 0.6)
                descText:SetJustifyH("LEFT")

                local btnX = -8

                -- Delete button
                local delBtn = GUI:CreateButton(row, L["Del"], 40, 24, function()
                    if DandersFramesDB_v2 and DandersFramesDB_v2.wizardConfigs then
                        DandersFramesDB_v2.wizardConfigs[name] = nil
                    end
                    pageWizards:Refresh()
                    if pageWizards.RefreshStates then pageWizards:RefreshStates() end
                end)
                delBtn:SetPoint("RIGHT", btnX, 0)
                btnX = btnX - 44

                -- Export button
                local exportBtn = GUI:CreateButton(row, L["Export"], 50, 24, function()
                    if DF.WizardBuilder then
                        local str, err = DF.WizardBuilder:ExportWizard(name)
                        if str then
                            -- Copy to clipboard via editbox
                            DF:ShowPopupAlert({
                                title = "Export Wizard",
                                message = "Wizard exported! Press Ctrl+C to copy the string below.",
                                width = 500,
                            })
                        else
                            print("|cffff0000DandersFrames:|r Export failed: " .. (err or "unknown"))
                        end
                    end
                end)
                exportBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
                btnX = btnX - 54

                -- Edit button (opens builder popup)
                local editBtn = GUI:CreateButton(row, L["Edit"], 40, 24, function()
                    if DF.ShowWizardBuilder then
                        DF:ShowWizardBuilder(name, function()
                            pageWizards:Refresh()
                            if pageWizards.RefreshStates then pageWizards:RefreshStates() end
                        end)
                    end
                end)
                editBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
                btnX = btnX - 44

                -- Run button
                local runBtn = GUI:CreateButton(row, L["Run"], 40, 24, function()
                    if DF.WizardBuilder then
                        local wizConfig = DF.WizardBuilder.BuildWizardConfig and DF.WizardBuilder.BuildWizardConfig(config)
                        if not wizConfig then
                            -- Fallback: build manually
                            wizConfig = {
                                title = config.title or config.name or "Wizard",
                                width = config.width or 440,
                                steps = DF:DeepCopy(config.steps),
                                settingsMap = config.settingsMap,
                                onComplete = function() DF:Debug("Wizard complete") end,
                            }
                        end
                        DF:ShowPopupWizard(wizConfig)
                    end
                end)
                runBtn:SetPoint("RIGHT", editBtn, "LEFT", -4, 0)

                Add(row, 54, "both")
            end
        end

        AddSpace(12, "both")

        -- Action buttons row
        local btnRow = CreateFrame("Frame", nil, self.child)
        btnRow:SetSize(460, 30)

        -- New Wizard button
        local newBtn = GUI:CreateButton(btnRow, L["+ New Wizard"], 120, 28, function()
            -- Generate unique name
            local baseName = "New Wizard"
            local wizName = baseName
            local counter = 1
            local existingConfigs = DandersFramesDB_v2 and DandersFramesDB_v2.wizardConfigs or {}
            while existingConfigs[wizName] do
                counter = counter + 1
                wizName = baseName .. " " .. counter
            end
            if DF.ShowWizardBuilder then
                DF:ShowWizardBuilder(wizName, function()
                    pageWizards:Refresh()
                    if pageWizards.RefreshStates then pageWizards:RefreshStates() end
                end)
            end
        end)
        newBtn:SetPoint("LEFT", 0, 0)

        -- Import button
        local importBtn = GUI:CreateButton(btnRow, L["Import"], 80, 28, function()
            DF:ShowPopupAlert({
                title = "Import Wizard",
                message = "Paste a wizard export string in chat with:\n/df importwizard <string>",
            })
        end)
        importBtn:SetPoint("LEFT", newBtn, "RIGHT", 8, 0)

        Add(btnRow, 34, "both")
    end)
    end  -- if false (wizards tab hidden)

    -- ========================================
    -- CATEGORY: Debug
    -- ========================================
    CreateCategory("debug", L["Debug"])

    -- Single page containing four collapsible sections in workflow order:
    -- Settings -> Categories -> Live Log -> Script Runner.
    -- All sections are collapsible and start expanded.
    local pageDebugConsole = CreateSubTab("debug", "debug_console", L["Console"])
    BuildPage(pageDebugConsole, function(self, db, Add, AddSpace, AddSyncPoint)

        -- Proxy for dropdown/slider keys (they don't support customGet/customSet)
        local debugProxy = setmetatable({}, {
            __index = function(_, k)
                return DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug[k]
            end,
            __newindex = function(_, k, v)
                if DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                    DandersFramesDB_v2.debug[k] = v
                end
            end,
        })

        -- Tracks the currently-open collapsible section so AddToSection() can
        -- automatically register subsequent widgets as its children.
        local currentSection = nil

        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then
                currentSection:RegisterChild(widget)
            end
            return widget
        end

        -- ============================================================
        -- 1) SETTINGS SECTION
        -- ============================================================
        local settingsSection = Add(GUI:CreateCollapsibleSection(self.child, L["Settings"], true), 36, "both")
        currentSection = settingsSection

        AddToSection(GUI:CreateCheckbox(self.child, L["Enable Debug Logging"], nil, nil, function()
            if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
        end, function()
            return DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.enabled or false
        end, function(val)
            if DF.DebugConsole then
                DF.DebugConsole:SetEnabled(val)
            elseif DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                DandersFramesDB_v2.debug.enabled = val
            end
        end), 28, "both")

        AddToSection(GUI:CreateCheckbox(self.child, L["Echo to Chat"], nil, nil, nil, function()
            return DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.chatEcho or false
        end, function(val)
            if DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                DandersFramesDB_v2.debug.chatEcho = val
            end
        end), 28, "both")

        local logLevelOptions = {
            ["INFO"]  = L["Info (All)"],
            ["WARN"]  = L["Warnings + Errors"],
            ["ERROR"] = L["Errors Only"],
        }
        AddToSection(GUI:CreateDropdown(self.child, L["Minimum Log Level"], logLevelOptions, debugProxy, "logLevel", function()
            if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
        end), 55, 1)

        AddToSection(GUI:CreateSlider(self.child, L["Max Log Entries"], 100, 10000, 100, debugProxy, "maxLines", function()
            if DF.DebugConsole then
                DF.DebugConsole:PruneLog()
                DF.DebugConsole:RefreshDisplay()
            end
        end), 55, 2)

        AddSyncPoint()

        -- ============================================================
        -- 2) LOGGED CATEGORIES SECTION
        -- ============================================================
        local categoriesSection = Add(GUI:CreateCollapsibleSection(self.child, L["Logged Categories"], true), 36, "both")
        currentSection = categoriesSection

        AddToSection(GUI:CreateLabel(self.child, "|cff888888" .. L["Unchecked categories are not logged at all. Disable noisy categories before reproducing a bug to keep the buffer focused."] .. "|r", 540), 36, "both")

        -- All / None buttons row
        local filterBtnRow = CreateFrame("Frame", nil, self.child)
        filterBtnRow:SetSize(540, 24)

        local function CollectAllCategories()
            local set = {}
            if DF.DebugConsole then
                for _, g in ipairs(DF.DebugConsole:GetCategoryGroups()) do
                    for _, cat in ipairs(g.categories) do
                        set[cat.key] = true
                    end
                end
                for cat in pairs(DF.DebugConsole:GetKnownCategories()) do
                    set[cat] = true
                end
            end
            return set
        end

        -- Track all created rows so All/None can refresh their visual state
        self.filterRows = {}
        local function RefreshAllRows()
            for _, row in pairs(self.filterRows) do
                if row.RefreshState then row:RefreshState() end
            end
            if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
        end

        local btnAll = GUI:CreateButton(filterBtnRow, L["All"], 60, 22, function()
            if DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                local filters = DandersFramesDB_v2.debug.filters
                for cat in pairs(CollectAllCategories()) do
                    filters[cat] = true
                end
            end
            RefreshAllRows()
        end)
        btnAll:SetPoint("LEFT", 0, 0)

        local btnNone = GUI:CreateButton(filterBtnRow, L["None"], 60, 22, function()
            if DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                local filters = DandersFramesDB_v2.debug.filters
                for cat in pairs(CollectAllCategories()) do
                    filters[cat] = false
                end
            end
            RefreshAllRows()
        end)
        btnNone:SetPoint("LEFT", btnAll, "RIGHT", 6, 0)

        AddToSection(filterBtnRow, 28, "both")

        if DF.DebugConsole then
            local groups = DF.DebugConsole:GetCategoryGroups()
            for _, group in ipairs(groups) do
                local groupLabel = L[group.name] or group.name
                AddToSection(GUI:CreateLabel(self.child, "|cffeda55f" .. groupLabel .. "|r", 540), 22, "both")
                for _, cat in ipairs(group.categories) do
                    local row = GUI:CreateDebugCategoryRow(self.child, cat.key, cat.desc, 540)
                    self.filterRows[cat.key] = row
                    AddToSection(row, 28, "both")
                end
            end

            -- Append auto-discovered categories that aren't in the registry
            local registered = DF.DebugConsole:GetRegisteredCategorySet()
            local known = DF.DebugConsole:GetKnownCategories()
            local extras = {}
            for cat in pairs(known) do
                if not registered[cat] then
                    tinsert(extras, cat)
                end
            end
            if #extras > 0 then
                table.sort(extras)
                AddToSection(GUI:CreateLabel(self.child, "|cffeda55f" .. L["Discovered"] .. "|r", 540), 22, "both")
                for _, cat in ipairs(extras) do
                    local row = GUI:CreateDebugCategoryRow(self.child, cat, nil, 540)
                    self.filterRows[cat] = row
                    AddToSection(row, 28, "both")
                end
            end
        end

        AddSyncPoint()

        -- ============================================================
        -- 3) LIVE LOG SECTION
        -- ============================================================
        local logSection = Add(GUI:CreateCollapsibleSection(self.child, L["Live Log"], true), 36, "both")
        currentSection = logSection

        -- Entry count label
        local entryCountLabel = GUI:CreateLabel(self.child, "", 540)
        local function UpdateEntryCount()
            local count = DF.DebugConsole and DF.DebugConsole:GetLogEntryCount() or 0
            entryCountLabel:SetText("|cff888888" .. format(L["Log entries: %d"], count) .. "|r")
        end
        UpdateEntryCount()
        AddToSection(entryCountLabel, 20, "both")

        -- Action buttons row (Refresh / Clear Log / Copy to Clipboard)
        local actionRow = CreateFrame("Frame", nil, self.child)
        actionRow:SetSize(540, 28)

        local refreshBtn = GUI:CreateButton(actionRow, L["Refresh"], 100, 24, function()
            if DF.DebugConsole then
                DF.DebugConsole:RefreshDisplay()
                UpdateEntryCount()
            end
        end)
        refreshBtn:SetPoint("LEFT", 0, 0)

        local clearBtn = GUI:CreateButton(actionRow, L["Clear Log"], 100, 24, function()
            if DF.DebugConsole then
                DF.DebugConsole:ClearLog()
                UpdateEntryCount()
            end
        end)
        clearBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)

        local copyBtn = GUI:CreateButton(actionRow, L["Copy to Clipboard"], 140, 24, function()
            if not DF.DebugConsole then return end
            local text = DF.DebugConsole:GetExportText()

            local popup = CreateFrame("Frame", "DFDebugExportPopup", UIParent, "BackdropTemplate")
            popup:SetSize(500, 350)
            popup:SetPoint("CENTER")
            popup:SetFrameStrata("DIALOG")
            popup:SetFrameLevel(200)
            GUI:CreatePanelBackdrop(popup)
            popup:EnableMouse(true)
            popup:SetMovable(true)
            popup:RegisterForDrag("LeftButton")
            popup:SetScript("OnDragStart", popup.StartMoving)
            popup:SetScript("OnDragStop", popup.StopMovingOrSizing)

            local title = popup:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
            title:SetPoint("TOP", 0, -10)
            title:SetText(L["Debug Log Export (Filtered)"])
            title:SetTextColor(0.9, 0.9, 0.9)

            local instructions = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            instructions:SetPoint("TOP", title, "BOTTOM", 0, -4)
            instructions:SetText(L["Press Ctrl+A to select all, then Ctrl+C to copy"])
            instructions:SetTextColor(0.6, 0.6, 0.6)

            local scrollContainer = CreateFrame("Frame", nil, popup, "BackdropTemplate")
            scrollContainer:SetPoint("TOPLEFT", 12, -45)
            scrollContainer:SetPoint("BOTTOMRIGHT", -12, 40)
            GUI:CreateElementBackdrop(scrollContainer, {
                bgColor = {0.05, 0.05, 0.05, 0.9},
                borderColor = {0.2, 0.2, 0.2, 1},
            })

            local scroll = CreateFrame("ScrollFrame", nil, scrollContainer, "ScrollFrameTemplate")
            scroll:SetPoint("TOPLEFT", 4, -4)
            scroll:SetPoint("BOTTOMRIGHT", -22, 4)
            GUI.StyleScrollBar(scroll)

            local editBox = CreateFrame("EditBox", nil, scroll)
            editBox:SetMultiLine(true)
            editBox:SetFontObject(DFFontHighlightSmall)
            editBox:SetWidth(440)
            editBox:SetAutoFocus(true)
            editBox:SetScript("OnEscapePressed", function() popup:Hide() end)
            scroll:SetScrollChild(editBox)

            editBox:SetText(text)
            editBox:HighlightText()

            local closeBtn = GUI:CreateButton(popup, L["Close"], 80, 24, function() popup:Hide() end)
            closeBtn:SetPoint("BOTTOM", 0, 10)

            popup:SetScript("OnHide", function(s)
                s:SetParent(nil)
                s:ClearAllPoints()
            end)
        end)
        copyBtn:SetPoint("LEFT", clearBtn, "RIGHT", 6, 0)

        AddToSection(actionRow, 32, "both")

        -- Full-width log viewer
        local logScrollContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        logScrollContainer:SetSize(540, 480)
        GUI:CreateElementBackdrop(logScrollContainer, {
            bgColor = {0.05, 0.05, 0.05, 0.9},
            borderColor = {0.2, 0.2, 0.2, 1},
        })

        local logScroll = CreateFrame("ScrollFrame", nil, logScrollContainer, "ScrollFrameTemplate")
        logScroll:SetPoint("TOPLEFT", 4, -4)
        logScroll:SetPoint("BOTTOMRIGHT", -22, 4)
        GUI.StyleScrollBar(logScroll)

        local logEditBox = CreateFrame("EditBox", nil, logScroll)
        logEditBox:SetMultiLine(true)
        logEditBox:SetFontObject(DFFontHighlightSmall)
        logEditBox:SetWidth(510)
        logEditBox:SetHeight(470)
        logEditBox:SetAutoFocus(false)
        logEditBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        logEditBox:SetScript("OnTextChanged", function(s, userInput)
            if userInput and DF.DebugConsole then
                DF.DebugConsole:RefreshDisplay()
            end
        end)
        logScroll:SetScrollChild(logEditBox)

        logScrollContainer:EnableMouse(true)
        logScrollContainer:SetScript("OnMouseDown", function() logEditBox:SetFocus() end)
        logScroll:EnableMouse(true)
        logScroll:SetScript("OnMouseDown", function() logEditBox:SetFocus() end)

        AddToSection(logScrollContainer, 485, "both")

        -- Register live EditBox with DebugConsole
        if DF.DebugConsole then
            DF.DebugConsole:SetLiveEditBox(logEditBox)
            DF.DebugConsole:RefreshDisplay()
            UpdateEntryCount()
        end

        -- Unregister on page hide
        self:SetScript("OnHide", function()
            if DF.DebugConsole then
                DF.DebugConsole:SetLiveEditBox(nil)
            end
        end)

        AddSyncPoint()

        -- ============================================================
        -- 4) SCRIPT RUNNER SECTION (developer-only utility, unrelated)
        -- ============================================================
        local scriptSection = Add(GUI:CreateCollapsibleSection(self.child, L["Script Runner"], true), 36, "both")
        currentSection = scriptSection

        local scriptScrollContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        scriptScrollContainer:SetSize(540, 120)
        GUI:CreateElementBackdrop(scriptScrollContainer, {
            bgColor = {0.05, 0.05, 0.05, 0.9},
            borderColor = {0.2, 0.2, 0.2, 1},
        })

        local scriptScroll = CreateFrame("ScrollFrame", nil, scriptScrollContainer, "ScrollFrameTemplate")
        scriptScroll:SetPoint("TOPLEFT", 4, -4)
        scriptScroll:SetPoint("BOTTOMRIGHT", -22, 4)
        GUI.StyleScrollBar(scriptScroll)

        local scriptEditBox = CreateFrame("EditBox", nil, scriptScroll)
        scriptEditBox:SetMultiLine(true)
        scriptEditBox:SetFontObject(DFFontHighlightSmall)
        scriptEditBox:SetWidth(510)
        scriptEditBox:SetHeight(112)
        scriptEditBox:SetAutoFocus(false)
        scriptEditBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        scriptEditBox:SetScript("OnTextChanged", function(s, userInput)
            if userInput and DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                DandersFramesDB_v2.debug.lastScript = s:GetText()
            end
        end)
        scriptScroll:SetScrollChild(scriptEditBox)

        if DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.lastScript then
            scriptEditBox:SetText(DandersFramesDB_v2.debug.lastScript)
        end

        scriptScrollContainer:EnableMouse(true)
        scriptScrollContainer:SetScript("OnMouseDown", function() scriptEditBox:SetFocus() end)
        scriptScroll:EnableMouse(true)
        scriptScroll:SetScript("OnMouseDown", function() scriptEditBox:SetFocus() end)

        AddToSection(scriptScrollContainer, 125, "both")

        local scriptStatusLabel = GUI:CreateLabel(self.child, "", 540)
        AddToSection(scriptStatusLabel, 20, "both")

        AddToSection(GUI:CreateButton(self.child, L["Run Script"], 540, 26, function()
            local code = scriptEditBox:GetText()
            if not code or code == "" then
                scriptStatusLabel:SetText("|cff666666No script to run.|r")
                return
            end
            local fn, err = loadstring(code)
            if not fn then
                scriptStatusLabel:SetText("|cffff6666Error: " .. tostring(err) .. "|r")
                DF:DebugError("SCRIPT", "Compile error: %s", tostring(err))
                return
            end
            local ok, result = pcall(fn)
            if ok then
                if result ~= nil then
                    scriptStatusLabel:SetText("|cff88ccffResult: " .. tostring(result) .. "|r")
                else
                    scriptStatusLabel:SetText("|cff88ff88Script executed successfully.|r")
                end
            else
                scriptStatusLabel:SetText("|cffff6666Runtime: " .. tostring(result) .. "|r")
                DF:DebugError("SCRIPT", "Runtime error: %s", tostring(result))
            end
        end), 32, "both")

        currentSection = nil
    end)

end
