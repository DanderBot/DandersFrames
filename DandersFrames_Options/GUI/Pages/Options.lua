-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local format = string.format

-- ============================================================
-- GUI PAGE SETUP - Collapsible Category System
-- ============================================================

function DF:SetupGUIPages(GUI, CreateCategory, CreateSubTab, BuildPage)
    local L = DF.L

    -- Note-style cross-link dropped in under a "Color by Time Remaining" toggle so users can
    -- jump to where the shared, account-wide breakpoint colours actually live (and see that
    -- section highlighted on arrival). `group` is the settings group the toggle sits in; `parent`
    -- is the page child frame. The link itself is GUI:CreateColorsPageLink (shared with the Aura Designer).
    local function AddColorsPageLink(group, parent)
        -- Shared note-style cross-link to the Colors page Color-by-Time section (jump + whole-
        -- section border flash). CreateLink is fixed-layout, so hand it the group's inner width
        -- up front — its wrapped height is then known before AddWidget (the group advances Y by
        -- the height we pass). Defined once in GUI:CreateColorsPageLink; shared with the Aura Designer.
        local note = GUI:CreateColorsPageLink(parent, GUI:GroupInnerWidth(group))
        group:AddWidget(note, (note.layoutHeight or 16) + 2)
        return note
    end

    -- Helper function to create a themed "Copy to Raid/Party" button for a
    -- section, plus the Sync toggle and the destructive Reset Page button.
    --
    -- Only for a section that is a BAG OF SETTINGS spread over many db keys —
    -- keeping those two bags in step is the whole point of a persistent link. A
    -- section holding ONE key the user can already set directly does not need
    -- it: the Aura and Text Designers own one key each (the template name), and
    -- their template dropdown IS the sharing control, so they carry neither
    -- button. See GUI:CreateDesignerPresetBar.
    local function CreateCopyButton(parent, prefixes, sectionName, pageId)
        -- Register section in the sync registry
        if pageId then
            DF.SectionRegistry[pageId] = prefixes
        end

        -- ☠ A page that owns NO per-mode keys gets no row at all. All three controls
        -- act on this page's registered prefixes, so with an empty list they render
        -- fully live -- hover, tooltip, click -- and do nothing whatsoever. Three
        -- convincing dead buttons is a worse failure than a missing row, and it is
        -- not hypothetical: the Filter Designer became exactly that page when filter
        -- selection moved out to the consumers, since what it edits is per PROFILE
        -- (preset overrides) and per ACCOUNT (custom filters) rather than per mode.
        --
        -- Returns an empty zero-height frame rather than nil: every caller Add()s the
        -- result straight into a page column, and nil there is a layout error.
        if type(prefixes) ~= "table" or #prefixes == 0 then
            local empty = CreateFrame("Frame", nil, parent)
            empty:SetSize(1, 1)
            empty.layoutHeight = 0
            return empty
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
            -- Snapped gap: the row is a CHAIN (Copy <- Sync <- Reset) and controls
            -- are no longer nudged onto the grid after the fact, so the offset
            -- itself has to be a whole number of device pixels or every button to
            -- the left of this one inherits the fraction.
            linkBtn:SetPoint("RIGHT", btn, "LEFT", GUI.SnapLen(linkBtn, -4), 0)
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
            btn:SetWidth(GUI.SnapLenUp(btn, math.ceil(btn.Text:GetStringWidth()) + 36))

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
                linkBtn:SetWidth(GUI.SnapLenUp(linkBtn, math.ceil(linkBtn.Text:GetStringWidth()) + 36))
            end
        end
        
        -- ☠ refreshContent IS THE HOOK PANEL ACTUALLY CALLS (Panel.lua's per-widget sweep).
        -- `UpdateModeText` below has NO callers anywhere in either addon — it was "stored
        -- for refresh" and nothing ever refreshed it, so this button's Copy label and its
        -- Synced/Sync state were painted once at build and then frozen. That was invisible
        -- while the only way to change link state was clicking this very button (which
        -- repaints itself), but a profile Reset clears linkedSections wholesale and the
        -- button went on claiming "Synced with Raid" until the page was rebuilt
        -- (Krathe, 2026-08-08). Kept the old field rather than deleting it unasked.
        -- ⚠ Called as widget:refreshContent(db) — colon, so it arrives (self, db).
        -- UpdateAppearance reads upvalues and ignores both, which is why it can be reused
        -- verbatim; do not give it parameters without checking these two call shapes.
        btn.refreshContent = UpdateAppearance
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
            GUI:HideTooltip()
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
                GUI:HideTooltip()
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
        local resetBtn = CreateFrame("Button", nil, btn, "BackdropTemplate")
        resetBtn:SetSize(115, 26)
        local gap = GUI.SnapLen(resetBtn, -4)   -- see the Sync gap above
        if linkBtn then
            resetBtn:SetPoint("RIGHT", linkBtn, "LEFT", gap, 0)
        else
            resetBtn:SetPoint("RIGHT", btn, "LEFT", gap, 0)
        end

        -- Destructive Reset: the shared danger tone owns the red label/icon +
        -- red hover; we keep the content-fit width + the tooltip hook.
        GUI:StyleButton(resetBtn, {
            tone = "danger",
            icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh", size = 18 },
            text = L["Reset Page"],
        })
        resetBtn:SetWidth(GUI.SnapLenUp(resetBtn, math.ceil(resetBtn.Text:GetStringWidth()) + 36))

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
        resetBtn:SetWidth(GUI.SnapLenUp(resetBtn, math.ceil(resetBtn.Text:GetStringWidth()) + 36))

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
        
        -- ⚠ Every box on this page has BOTH an "Anchor To" and an "Anchor", which
        -- is the one genuinely confusing thing here: the first picks WHAT the
        -- tooltip attaches to, the second WHERE on it. Written once and applied to
        -- all five pairs rather than five times over.
        local TIP_ANCHOR_TO = L["What the tooltip attaches to. Game Default hands it back to Blizzard's own placement; Cursor follows the mouse; Unit Frame pins it to the frame you are hovering."]
        local TIP_ANCHOR_POS = L["Which point of the thing above the tooltip hangs from. Greyed out under Game Default, because Blizzard is placing it."]

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
        local frameAnchorTo = frameTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], frameAnchorValues, db, "tooltipFrameAnchor", function() GUI:RefreshCurrentPage() end), 55)
        frameAnchorTo.tooltip = TIP_ANCHOR_TO

        local frameAnchorPos = frameTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipFrameAnchorPos", function() end), 55)
        frameAnchorPos.disableOn = function(d) return d.tooltipFrameAnchor == "DEFAULT" end
        frameAnchorPos.tooltip = TIP_ANCHOR_POS
        
        local frameOffsetX = frameTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "tooltipFrameX", function() end), 55)
        frameOffsetX.disableOn = function(d) return d.tooltipFrameAnchor ~= "FRAME" end
        
        local frameOffsetY = frameTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "tooltipFrameY", function() end), 55)
        frameOffsetY.disableOn = function(d) return d.tooltipFrameAnchor ~= "FRAME" end
        
        Add(frameTooltipGroup, nil, 1)

        -- Binding Tooltips (Column 2) — pairs with Frame Tooltips: both anchor to
        -- the Unit Frame, so they are the two boxes describing the SAME hover.
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
        local bindAnchorTo = bindTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], bindAnchorValues, db, "tooltipBindingAnchor", function() GUI:RefreshCurrentPage() end), 55)
        bindAnchorTo.tooltip = TIP_ANCHOR_TO

        local bindAnchorPos = bindTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipBindingAnchorPos", function() end), 55)
        bindAnchorPos.disableOn = function(d) return d.tooltipBindingAnchor == "DEFAULT" end
        bindAnchorPos.tooltip = TIP_ANCHOR_POS

        local bindOffsetX = bindTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "tooltipBindingX", function() end), 55)
        bindOffsetX.disableOn = function(d) return d.tooltipBindingAnchor ~= "FRAME" end

        local bindOffsetY = bindTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "tooltipBindingY", function() end), 55)
        bindOffsetY.disableOn = function(d) return d.tooltipBindingAnchor ~= "FRAME" end

        Add(bindTooltipGroup, nil, 2)

        -- Buff Tooltips (Column 1)
        local buffTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        buffTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Buff Tooltips"]), 40)
        -- 12.1 factory rows read all of these on the layout-version bump: the Enable
        -- toggle is structural (mouse-motion opt-in, in the row sig -> Rebuild), while
        -- anchor/offsets/combat-hide ride style.tooltip and restyle in place
        -- (SetTooltipAnchorPoint/SetHideTooltipInCombat are live mixin state, 68914+).
        local RefreshAuraTooltips = function()
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            DF:UpdateAllFrames()
        end
        local buffTooltipEnable = buffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Buff Tooltips"], db, "tooltipBuffEnabled", RefreshAuraTooltips), 30)
        buffTooltipEnable.keepEnabled = true
        buffTooltipGroup.disableChildrenOn = function(d) return not d.tooltipBuffEnabled end
        buffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Disable in Combat"], db, "tooltipBuffDisableInCombat", RefreshAuraTooltips), 30)

        local buffAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Buff Icon"],
        }
        local buffAnchorTo = buffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], buffAnchorValues, db, "tooltipBuffAnchor", function() RefreshAuraTooltips() GUI:RefreshCurrentPage() end), 55)
        buffAnchorTo.tooltip = TIP_ANCHOR_TO

        local buffAnchorPos = buffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipBuffAnchorPos", RefreshAuraTooltips), 55)
        buffAnchorPos.disableOn = function(d) return d.tooltipBuffAnchor == "DEFAULT" end
        buffAnchorPos.tooltip = TIP_ANCHOR_POS

        local buffOffsetX = buffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "tooltipBuffX", RefreshAuraTooltips), 55)
        buffOffsetX.disableOn = function(d) return d.tooltipBuffAnchor ~= "FRAME" end

        local buffOffsetY = buffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "tooltipBuffY", RefreshAuraTooltips), 55)
        buffOffsetY.disableOn = function(d) return d.tooltipBuffAnchor ~= "FRAME" end
        
        Add(buffTooltipGroup, nil, 1)

        -- ⚠ NO sync points between these boxes. Every tooltip box bar Resurrection
        -- is the same 320 tall by construction (header 40 + enable 30 + combat 30
        -- + two dropdowns at 55 + two sliders at 55), so the two columns stay level
        -- on their own — the old "align row N" sync points bought nothing, and one
        -- of them actively hurt: column 2 carries Resurrection (70) as a third box,
        -- so syncing after it dropped BOTH columns to column 2's bottom and left a
        -- ~70px hole in column 1 between Debuff and Binding.
        --
        -- 5 boxes of 320 plus one of 70 cannot be split evenly, so the short box
        -- belongs at the bottom of the SHORTER column (column 2), where a trailing
        -- gap reads as the end of a column rather than as a mistake.

        -- Debuff Tooltips (Column 1)
        local debuffTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        debuffTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Debuff Tooltips"]), 40)
        local debuffTooltipEnable = debuffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Debuff Tooltips"], db, "tooltipDebuffEnabled", RefreshAuraTooltips), 30)
        debuffTooltipEnable.keepEnabled = true
        debuffTooltipGroup.disableChildrenOn = function(d) return not d.tooltipDebuffEnabled end
        debuffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Disable in Combat"], db, "tooltipDebuffDisableInCombat", RefreshAuraTooltips), 30)

        local debuffAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Debuff Icon"],
        }
        local debuffAnchorTo = debuffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], debuffAnchorValues, db, "tooltipDebuffAnchor", function() RefreshAuraTooltips() GUI:RefreshCurrentPage() end), 55)
        debuffAnchorTo.tooltip = TIP_ANCHOR_TO

        local debuffAnchorPos = debuffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipDebuffAnchorPos", RefreshAuraTooltips), 55)
        debuffAnchorPos.disableOn = function(d) return d.tooltipDebuffAnchor == "DEFAULT" end
        debuffAnchorPos.tooltip = TIP_ANCHOR_POS

        local debuffOffsetX = debuffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "tooltipDebuffX", RefreshAuraTooltips), 55)
        debuffOffsetX.disableOn = function(d) return d.tooltipDebuffAnchor ~= "FRAME" end

        local debuffOffsetY = debuffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "tooltipDebuffY", RefreshAuraTooltips), 55)
        debuffOffsetY.disableOn = function(d) return d.tooltipDebuffAnchor ~= "FRAME" end
        
        Add(debuffTooltipGroup, nil, 2)

        -- Defensive Icon Tooltips (Column 1)
        local defTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        defTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Defensive Icon Tooltips"]), 40)
        local defTooltipEnable = defTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Defensive Icon Tooltips"], db, "tooltipDefensiveEnabled", RefreshAuraTooltips), 30)
        defTooltipEnable.keepEnabled = true
        defTooltipGroup.disableChildrenOn = function(d) return not d.tooltipDefensiveEnabled end
        defTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Disable in Combat"], db, "tooltipDefensiveDisableInCombat", RefreshAuraTooltips), 30)

        local defAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Defensive Icon"],
        }
        local defAnchorTo = defTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], defAnchorValues, db, "tooltipDefensiveAnchor", function() RefreshAuraTooltips() GUI:RefreshCurrentPage() end), 55)
        defAnchorTo.tooltip = TIP_ANCHOR_TO

        local defAnchorPos = defTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorPositionValues, db, "tooltipDefensiveAnchorPos", RefreshAuraTooltips), 55)
        defAnchorPos.disableOn = function(d) return d.tooltipDefensiveAnchor == "DEFAULT" end
        defAnchorPos.tooltip = TIP_ANCHOR_POS

        local defOffsetX = defTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "tooltipDefensiveX", RefreshAuraTooltips), 55)
        defOffsetX.disableOn = function(d) return d.tooltipDefensiveAnchor ~= "FRAME" end

        local defOffsetY = defTooltipGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "tooltipDefensiveY", RefreshAuraTooltips), 55)
        defOffsetY.disableOn = function(d) return d.tooltipDefensiveAnchor ~= "FRAME" end
        
        Add(defTooltipGroup, nil, 1)

        -- Aura Designer Tooltips (Column 2). Lives HERE rather than on the Aura
        -- Designer page: this setting only ever gets touched by someone who
        -- wants a tooltip and hasn't got one, or has one and doesn't want it —
        -- and both of those people go looking for "tooltip". The AD page links
        -- across via its See Also row.
        --
        -- Split by AD surface rather than one blanket toggle, because the value
        -- differs sharply. GROUPS render whatever matches a filter, so you never
        -- chose those icons — that is the case worth having. Indicators and Bars
        -- are spells you placed and named yourself, so they gain little, but
        -- there's no harm in offering them.
        local adTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        adTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Aura Designer Tooltips"]), 40)
        local adGroupsTip = adTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Groups"], db, "tooltipADGroupsEnabled", RefreshAuraTooltips), 30)
        adGroupsTip.tooltip = L["Filter Groups and Debuff Groups. Their icons come from a filter rather than being placed one by one, so a tooltip is the only way to see what each one is."]
        local adIndTip = adTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Indicators"], db, "tooltipADIndicatorsEnabled", RefreshAuraTooltips), 30)
        adIndTip.tooltip = L["Icons and squares you placed yourself. You already chose these, so tooltips add less here."]
        local adBarTip = adTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Bars"], db, "tooltipADBarsEnabled", RefreshAuraTooltips), 30)
        adBarTip.tooltip = L["The Aura Designer bar."]
        Add(adTooltipGroup, nil, 2)

        -- Resurrection Icon Tooltips (Column 2) — the one short box, kept last so
        -- the leftover space lands at the foot of a column.
        local resTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        resTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Resurrection Icon Tooltips"]), 40)
        resTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Resurrection Icon Tooltips"], db, "tooltipResurrectionEnabled", nil), 30)
        Add(resTooltipGroup, nil, 2)

        -- Sync point before See Also
        AddSyncPoint()
        AddSpace(GUI.Space.block, "both")

        -- See Also links
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buff Bar"]},
            {pageId = "auras_debuffs", label = L["Debuff Bar"]},
            {pageId = "auras_defensiveicon", label = L["Defensive Icon"]},
            {pageId = "auras_auradesigner", label = L["Aura Designer"]},
        }), 30, "both")
    end)

    -- Display > Fading (moved from Indicators > Out of Range + Dead/Offline fading)
    local pageFading = CreateSubTab("display", "display_fading", L["Fading"])
    BuildPage(pageFading, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right.
        -- ☠ These prefixes are matched CASE-SENSITIVELY from the START of the key
        -- (DF:SectionOwnsKey), and the SAME list drives Copy, Sync AND Reset Page.
        -- "dead" and "offline" matched nothing: the keys are fadeDead*, which begins
        -- "fade". So the entire Dead/Offline Fading box was silently dropped from all
        -- three. Prefixes must be real key prefixes, not the box's name.
        Add(CreateCopyButton(self.child, {"rangeFade", "rangeCheck", "rangeUpdate", "oor", "fadeDead", "healthFade", "hf"}, L["Fading"], "display_fading"), 25, 2)
        
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
                    DF:Say("Range spell set to " .. spellName, "ID " .. spellID)
                else
                    DF:Err("Invalid spell ID: " .. spellID)
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
        
        -- (Removed) the Targeted Spell Alpha slider on oorTargetedSpellAlpha. Its only
        -- consumer was DF:UpdateTargetedSpellAppearance, which faded the group-frame
        -- container and went with that display. Personal Targeted is a screen overlay
        -- that never ran through ElementAppearance's out-of-range path, and the
        -- Targeted List has its own container and colours — so the slider was moving
        -- a value nothing read.

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
        
        -- ===== HEALTH THRESHOLD FADING (col2) =====
        -- Column width, and the spacer above it is column 2 as well. A "both"
        -- widget takes the LOWER of the two columns and drops both to it, so a
        -- "both" spacer here would push column 2 down past the bottom of the
        -- out-of-range group in column 1 and leave a hole under Dead/Offline.
        --
        -- Column 2 rather than 1 because column 1 carries the out-of-range group
        -- and its long stack of per-element sliders, far and away the tallest
        -- thing on the page.
        AddSpace(GUI.Space.block, 2)
        local hfGroup = GUI:CreateSettingsGroup(self.child, 280)
        hfGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Threshold Fading"]), 40)

        local hfEnable = hfGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Health Threshold Fade"], db, "healthFadeEnabled", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)
        hfEnable.keepEnabled = true
        -- Was set on hfGroup, which is a SettingsGroup and has no tooltip support,
        -- so this explanation had never once been seen. It belongs on the enable
        -- toggle anyway — that's the control you hover to ask "what is this?".
        hfEnable.tooltip = L["Fade frames or elements when a unit's health is above the set threshold (e.g. 100% or 80%)."]
        hfGroup.disableChildrenOn = function(d) return not d.healthFadeEnabled end

        local hfThreshold = hfGroup:AddWidget(GUI:CreateSlider(self.child, L["Health Threshold (%)"], 50, 100, 1, db, "healthFadeThreshold", function()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 55)
        hfThreshold.tooltip = L["Units at or above this health percent are faded."]

        hfGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Cancel Fade on Dispellable Debuff"], db, "hfCancelOnDispel", function()
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

        Add(hfGroup, nil, 2)
        
        -- See Also links
        AddSpace(GUI.Space.block, "both")
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
        
        -- ===== GENERAL GROUP (col1) =====
        -- Column width, not full width. A full-width box belongs to a page that
        -- genuinely needs the room -- Pinned Frames, Nicknames -- and everything
        -- below these two here is ordinary two-column controls, so stretching
        -- them across the top reads as two different layouts stacked together.
        local generalGroup = GUI:CreateSettingsGroup(self.child, 280)
        generalGroup:AddWidget(GUI:CreateHeader(self.child, L["Pet Frame Settings"]), 40)
        local petEnable = generalGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Pet Frames"], db, "petEnabled", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            self:RefreshStates()
        end), 30)
        petEnable.keepEnabled = true
        generalGroup.disableChildrenOn = function(d) return not d.petEnabled end
        -- No slot height on the blurbs here or in the group below: at 250 they
        -- wrap to more lines than they did at 530, and CreateLabel measures
        -- itself whenever the call site does not pin it. Guessing a replacement
        -- number by hand is what puts a blurb through the control beneath it.
        generalGroup:AddWidget(GUI:CreateLabel(self.child, L["Show health bars for player and party/raid member pets, anchored to their owner's frame. Pet frames hide when owner dies."], 250))
        Add(generalGroup, nil, 1)

        -- ===== LAYOUT MODE GROUP (col1) =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout Mode"]), 40)
        layoutGroup.disableChildrenOn = function(d) return not d.petEnabled end

        local groupModeValues = {
            ATTACHED = L["Attached to Owner"],
            GROUPED = L["Separate Pet Group"],
        }
        local petLayoutMode = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Layout Mode"], groupModeValues, db, "petGroupMode", function()
            if DF.UpdateAllPetFrames then DF:UpdateAllPetFrames(true) end
            if DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
            GUI:RefreshCurrentPage()
        end), 55)
        petLayoutMode.tooltip = L["Attached puts each pet beside its owner's frame, so you read them together. Separate Pet Group collects every pet into one block you can place anywhere. The rest of this page changes to match your choice."]

        if not isGroupedMode then
            layoutGroup:AddWidget(GUI:CreateLabel(self.child, L["Pet frames are positioned relative to their owner's frame."], 250))
        else
            layoutGroup:AddWidget(GUI:CreateLabel(self.child, L["Pet frames are grouped together in a separate container."], 250))
        end
        Add(layoutGroup, nil, 1)

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
            
            local petGroupPos = groupedSettingsGroup:AddWidget(GUI:CreateDropdown(self.child, L["Group Position"], groupAnchorValues, db, "petGroupAnchor", updateFunc), 55)
            petGroupPos.tooltip = L["Which side of your party or raid frames the whole pet block sits on. Use the offsets below to nudge it from there."]
            
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
            local petMatchW = sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Match Owner Width"], db, "petMatchOwnerWidth", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
                GUI:RefreshCurrentPage()
            end), 30)
            petMatchW.tooltip = L["Sizes each pet frame to its owner's, so the pair stays aligned when you resize the unit frames. The Width slider below greys out while this is on."]
            local petMatchH = sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Match Owner Height"], db, "petMatchOwnerHeight", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
                GUI:RefreshCurrentPage()
            end), 30)
            petMatchH.tooltip = L["Sizes each pet frame to its owner's, so the pair stays aligned when you resize the unit frames. The Height slider below greys out while this is on."]
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
        -- Offset X / Y in the Position group in column 1), class / role colour
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
        Add(petBorderGroup, nil, 2)
        
        -- HEALTH BAR GROUP (col2)
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

        Add(healthBarGroup, nil, 2)
        
        -- NAME TEXT GROUP (col2)
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
        Add(nameTextGroup, nil, 2)
        
        -- POSITION GROUP (col1, Attached mode only)
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
            -- ☠ LightweightUpdatePetFrames, NOT UpdateAllPetFramePositions: the
            -- latter branches only on the LIVE tracks (party/raid/arena), so in
            -- test mode these controls silently did nothing on keyboard entry —
            -- mouse drags only "worked" because drag-release runs a full update
            -- that happens to cover test pets (#1047). The lightweight pass is
            -- track-aware, test modes included.
            positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorValues, db, "petAnchor", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "petOffsetX", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "petOffsetY", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            
            Add(positionGroup, nil, 1)
        end
        
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

        -- The Blizzard-frame disable is applied ONCE at load (a hard, ElvUI-style
        -- UnregisterAllEvents + reparent of the CompactRaidFrameManager that can't
        -- be cleanly undone live), so changing any of these toggles needs a UI
        -- reload to take full effect. The setter still hides/shows the frames
        -- immediately for feedback; this prompt handles the permanent part.
        local function PromptReloadBlizzard()
            if not DF.ShowPopupAlert then return end
            DF:ShowPopupAlert({
                title = L["Reload Required"],
                message = L["Disabling or enabling the Blizzard frames requires a UI reload to take full effect.\n\nReload now?"],
                buttons = {
                    { label = L["Reload Now"], onClick = function() ReloadUI() end },
                    { label = L["Reload Later"] },
                },
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
            function() PromptReloadBlizzard() end,
            makeBlizGet("hideBlizzardPartyFrames"),
            makeBlizSet("hideBlizzardPartyFrames", function() DF:UpdateBlizzardFrameVisibility() end)
        ), 30)
        disablePartyCheck.tooltip = L["Hides and unregisters all events on the default Blizzard party frames so they consume no performance."]

        local disableRaidCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(
            self.child, L["Disable Blizzard Raid Frames"],
            DF.db.party, "hideBlizzardRaidFrames",
            function() PromptReloadBlizzard() end,
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

        -- Visual divider to separate the related sub-option (Show Side Menu only
        -- applies once a Blizzard frame is disabled).
        --
        -- This rule was hand-rolled here first; it is now GUI:CreateSeparator, so the
        -- Buff Bar page's scope/filter split draws the identical line instead of a
        -- second copy of the same five lines.
        blizzardGroup:AddWidget(GUI:CreateSeparator(self.child), 14)

        local sideMenuCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(
            self.child, L["Show Party/Raid Side Menu"],
            DF.db.party, "showBlizzardSideMenu",
            function() PromptReloadBlizzard() end,
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
        -- Label slots below are sized for the WRAPPED text plus a gap. Labels are
        -- variable-height widgets (GUI.RowHeight only governs fixed ones), so the
        -- slot is whatever is passed here — too small and the next widget's label
        -- sits on the last line of this one.
        renderingGroup:AddWidget(GUI:CreateLabel(self.child,
            L["Snaps sizes and borders to exact pixels for crisp rendering."], 250), 42)
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
            -- 3 wrapped lines (~48px) + a clear gap before the dropdown below.
            renderingGroup:AddWidget(scaleHint, 72)
        end
        -- Aura duration-text update rate (account-wide, DF.GlobalDefaults). Feeds the
        -- native duration binding at bind time (creation-frozen), so a change is
        -- structural: invalidate the memoized value + re-drive rows AND the Aura
        -- Designer (the ApplyColorByTime pattern — the other global folded into the
        -- aura struct sigs).
        local auraDurRateValues = {
            SMOOTH = L["Smooth"], NORMAL = L["Normal"], PERFORMANCE = L["Performance"],
            _order = { "SMOOTH", "NORMAL", "PERFORMANCE" },
        }
        renderingGroup:AddWidget(GUI:CreateDropdown(self.child, L["Aura Duration Update Rate"],
            auraDurRateValues, DF:GetGlobalDB(), "auraDurationUpdateInterval", function()
                if DF.InvalidateAuraDurationUpdateInterval then DF:InvalidateAuraDurationUpdateInterval() end
                if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
                if DF.UpdateAllFrames then DF:UpdateAllFrames() end
                if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end), 55)
        renderingGroup:AddWidget(GUI:CreateLabel(self.child,
            L["How often aura countdown text refreshes. Smooth updates ten times a second, Performance once a second. Normal keeps the standard rate."],
            250), 52)
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
        local loginMsgCheck = notificationsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show the login message"],
            DF:GetGlobalDB(), "showLoginMessage", function()
                -- Read once at login; nothing to re-render now.
            end), 30)
        loginMsgCheck.tooltip = L["The one-line greeting printed to chat when you log in. Takes effect at your next login."]
        Add(notificationsGroup, nil, 2)
    end)

    -- General > Frame
    local pageFrame = CreateSubTab("general", "general_frame", L["Frame"])
    BuildPage(pageFrame, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        -- "background"/"missingHealth" belong to bars_health (which hosts all
        -- controls for those keys) — not registered here so its Copy/Sync/Reset
        -- solely owns them.
        -- "permanentMover" (16 keys) was reached by nothing: the whole permanent
        -- mover was skipped by Copy, Sync and Reset. ("border" and "anchor" match
        -- nothing either — the real keys are frameBorder* / frameAnchor*, already
        -- covered by "frame"; left in place as harmless intent.)
        --
        -- ⚠ DELIBERATELY NOT LISTED: the 14 raid* layout keys (raidUseGroups,
        -- raidPlayersPerRow, raidGroup*, raidFlat*, raidRowColSpacing...). They are
        -- per-mode and so DO exist on the party side, but only the raid page ever
        -- edits them — so party's copies sit at their untouched defaults. One list
        -- drives Copy, Sync AND Reset, so owning them would make "Copy to Raid" from
        -- the party page overwrite the user's raid layout with those defaults. The
        -- cost of leaving them out is that Reset Page does not clear raid layout;
        -- that is the lesser of the two, and fixing it properly needs per-direction
        -- ownership, which SectionOwnsKey does not currently express.
        --
        -- ☠ growDirection / growthAnchor BELONG TO THAT SAME EXCLUSION and were
        -- wrongly added to it (3b912fb0, alongside permanentMover). They are exactly
        -- the case the paragraph above describes -- per-mode, edited from BOTH the
        -- party and raid pages -- and they escaped it only because they are not
        -- spelled "raid...". Owning them meant Sync with Raid overwrote the raid
        -- growth direction from party's every refresh, so raid could never keep a
        -- different one: field-reported as an imported profile arriving with raid
        -- laid out in columns instead of rows, reproducible on every import. The
        -- import was never at fault; the post-import refresh re-synced it.
        --
        -- ☠ THE SYMPTOM IS ALMOST INVISIBLE. The sync copies every key under these
        -- prefixes, but party and raid agree on nearly all of them, so the only
        -- evidence is the one key where a user's two modes genuinely differ.
        -- growDirection is that key for most people; do not read "only one setting
        -- moved" as "small blast radius".
        --
        -- ⚠ This block used to cite the raid dropdown's INVERTED labels (HORIZONTAL
        -- reading as "Columns" there and "Rows" on party/flat) as the clearest signal
        -- these were never meant to be one shared setting. That inversion was a plain
        -- labelling bug and is gone -- there is one dropdown now, see the note beside
        -- it. The exclusion below stands on its own: the key is per-mode and edited
        -- from both pages, which is what makes owning it here destructive.
        Add(CreateCopyButton(self.child, {"frame", "permanentMover", "border", "anchor"}, L["Frame"], "general_frame"), 25, 2)
        
        -- Migration: Ensure new flat raid settings have defaults
        if db.raidFlatGrowthAnchor == nil then db.raidFlatGrowthAnchor = "START" end
        if db.raidFlatFrameAnchor == nil then db.raidFlatFrameAnchor = "START" end
        if db.raidFlatColumnAnchor == nil then db.raidFlatColumnAnchor = "START" end
        
        -- Function to update the correct frames based on mode
        local function UpdateFrames()
            -- ⚠ FORCED, and it must come first. This is the only path that re-anchors the
            -- health bar to framePadding; ApplyHeaderSettings below re-applies frame WIDTH
            -- and HEIGHT through the secure header, which is why those two looked fine
            -- while padding did not. `true` skips the drag throttle — an un-forced call
            -- landing inside the drag window would silently do nothing, which is the
            -- failure this is here to prevent (Krathe, 2026-08-09).
            if DF.LightweightUpdateFrameSize then
                DF:LightweightUpdateFrameSize(true)
            end
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
            -- Match-owner pets follow an owner resize made by KEYBOARD too:
            -- this callback had no pet call at all, so a typed Frame Width/
            -- Height never reached pets until some full pet pass ran (mouse
            -- drags only worked via the drag-release full update, #1047). The
            -- lightweight pass is track-aware and re-reads owner dimensions.
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
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
        
        -- Column 1 is the layout chain -- size, direction, raid mode, and
        -- whichever group detail that mode implies. Column 2 keeps
        -- Appearance at the top, where styling sits on every other page.
        --
        -- Six boxes against three is not the imbalance it looks: FIVE of
        -- the left column's boxes are raid-only, so in party mode the page
        -- is Frame Size + Layout Direction against Appearance + Permanent
        -- Mover. Permanent Mover is also by far the biggest box here, which
        -- carries column 2 in raid.
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
        
        -- ☠ ONE DROPDOWN FOR ALL THREE LAYOUTS, AND IT HAS TO STAY ONE.
        -- There were three -- party, raid+groups and raid+flat -- mutually exclusive by
        -- hideOn, and the raid+groups one INVERTED the pair: HORIZONTAL read as "Columns"
        -- there and "Rows" in the other two. Every label that depends on the same key
        -- (Groups Per Row / Row Spacing / Rows Grow From, and the hint below) uses the
        -- party reading, so picking "Rows" in a grouped raid produced a box full of
        -- Column settings -- field-reported as "choosing columns enables rows
        -- configuration, and viceversa" (Aphoex, 2026-08-14).
        -- Both readings describe the same layout truthfully (HORIZONTAL lays the
        -- repeating unit left-to-right, and in groups mode that unit IS a vertical column
        -- of five players), which is exactly why the disagreement survived: neither side
        -- looks wrong on its own. The union of the three hideOns is "never hidden", so
        -- collapsing them costs nothing and makes a future divergence impossible.
        -- ⇒ HORIZONTAL = the unit grows left-to-right = "Rows". Do not re-split this.
        local growOptions = { HORIZONTAL = L["Rows"], VERTICAL = L["Columns"] }
        layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growOptions, db, "growDirection", OnGrowthDirectionChanged), 55)

        -- Growth anchor (party only)
        local anchorOptions = { START= L["Start (Left/Top)"], CENTER= L["Center"], END= L["End (Right/Bottom)"] }
        local anchorDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Frames Grow From"], anchorOptions, db, "growthAnchor", UpdateFrames), 55)
        anchorDropdown.hideOn = function() return GUI.SelectedMode == "raid" end
        
        Add(layoutGroup, nil, 1)
        
        -- ===== RAID LAYOUT MODE GROUP (Column 1, raid only) =====
        local raidModeGroup = GUI:CreateSettingsGroup(self.child, 280)
        raidModeGroup:AddWidget(GUI:CreateHeader(self.child, L["Raid Layout Mode"]), 40)
        raidModeGroup.hideOn = function() return GUI.SelectedMode ~= "raid" end
        
        raidModeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Group-Based Layout"], db, "raidUseGroups", function()
            UpdateFrames()
            if DF.SecureSort then
                DF.SecureSort:PushRaidGroupLayoutConfig()
                DF.SecureSort:TriggerSecureRaidSort()
            end
            -- Branch on the SETTING only. Folding `not InCombatLockdown()` into this
            -- test meant that switching TO flat mode while in combat fell into the
            -- else branch and disabled flat mode outright -- the opposite of what
            -- the user asked for. SetEnabled already defers correctly in combat
            -- (it queues pendingVisibility and replays at PLAYER_REGEN_ENABLED), so
            -- just tell it the truth and let it schedule.
            if not db.raidUseGroups then
                if not InCombatLockdown() and DF.UpdateRaidGroupLabels then DF:UpdateRaidGroupLabels() end
                C_Timer.After(0, function()
                    if DF.FlatRaidFrames then
                        if not DF.FlatRaidFrames.initialized and not InCombatLockdown() then
                            DF.FlatRaidFrames:Initialize()
                        end
                        if DF.FlatRaidFrames.initialized then DF.FlatRaidFrames:SetEnabled(true) end
                    end
                    if not InCombatLockdown() then
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
        Add(raidModeGroup, nil, 1)
        
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
        local rowGrowDrop = groupLayoutGroup:AddWidget(GUI:CreateDropdown(self.child, rowGrowLabel, rowGrowOptions, db, "raidGroupRowGrowth", UpdateFrames), 55)
        -- ☠ INERT AT 8 GROUPS PER ROW, WHICH IS THE DEFAULT. Both positioners flip the row
        -- index as `rcIdx = (fullGridRC - 1) - rcIdx`, and both derive fullGridRC from the
        -- FULL eight groups: `ceil(8 / groupsPerRow)`. At 8 per row that is 1, so the flip is
        -- the IDENTITY and End renders exactly like Start — correct for a single row, since
        -- one row cannot grow from either end differently, but the control stayed live and
        -- said nothing. Reported as "Rows Grow From only applies Start, End doesn't do
        -- anything", in both growth directions (Aphoex 8) — and both directions are the same
        -- single-row case, because Columns Grow From is this very key under a swapped label.
        -- ⚠ Greyed rather than hidden, and deliberately NOT clamped to the populated group
        -- count: the flip is intentionally over the FULL grid (see the note in
        -- Features/SecureSort.lua), so with fewer than eight groups End legitimately moves
        -- them to the bottom of the eight-group grid. Only the one-row case is a true no-op.
        rowGrowDrop.disableOn = function(d) return (d.raidGroupsPerRow or 8) >= 8 end

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
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_sorting", label = L["Sorting"]},
            {pageId = "bars_health", label = L["Health Bar"]},
            -- LEGACY-TEXT-CLEANUP: legacy text page hidden; link removed
            -- {pageId = "text_name", label = L["Name Text"]},
        }), 30, "both")
    end)
    
    -- General > Global Fonts
    DF._SetupGUIPagesPart2(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
end