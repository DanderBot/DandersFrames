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
        
        -- Hold To Show is PER BOX, declared once here and added inside each group
        -- that supports it, directly under that group's Disable In Combat. Sharing
        -- the value list and tooltip keeps the two identical without repeating them.
        -- ⚠ Only Frame and Binding get one. The buff / debuff / defensive rows are
        -- drawn by the game's own aura buttons and DF cannot gate them on a keypress
        -- (the mouse-motion lever is write-locked in combat) -- so rather than show
        -- a permanently dead control in those boxes, they simply do not have one.
        -- ★ ONE VOCABULARY, ASKED TWICE -- once for out of combat, once for in
        -- combat. "Alt out of combat, never in combat" is then two picks that cannot
        -- contradict each other, which a Disable-In-Combat checkbox plus a separate
        -- hold-to-show dropdown genuinely could. Same shape ElvUI uses (its
        -- visibility.unitFrames + visibility.combatOverride take these five values);
        -- Ellesmere reaches the same place with a single always/outOfCombat/never
        -- mode. Only the two DF-drawn boxes get it -- see the config comment for why
        -- the aura rows cannot.
        local VIS_VALUES = {
            SHOW  = L["Always"],
            SHIFT = L["Hold Shift"],
            CTRL  = L["Hold Ctrl"],
            ALT   = L["Hold Alt"],
            HIDE  = L["Never"],
            _order = { "SHOW", "SHIFT", "CTRL", "ALT", "HIDE" },
        }
        local TIP_VIS_OOC = L["When this tooltip appears while you are out of combat. Always shows it on hover; a Hold option requires that key; Never suppresses it."]
        local TIP_VIS_COMBAT = L["When this tooltip appears while you are in combat, independently of the out-of-combat setting. Set this to Never and no key will reveal it mid-fight. Press or release a Hold key while already hovering and the tooltip follows immediately."]

        -- ===== ROW 1: Frame Tooltips + Buff Tooltips =====

        -- Frame Tooltips (Column 1)
        local frameTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Tooltips"]), 40)
        local frameTooltipEnable = frameTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Frame Tooltips"], db, "tooltipFrameEnabled", nil), 30)
        frameTooltipEnable.keepEnabled = true
        frameTooltipGroup.disableChildrenOn = function(d) return not d.tooltipFrameEnabled end
        local frameVisOOC = frameTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Show Out of Combat"],
            VIS_VALUES, db, "tooltipFrameOutOfCombat", function() end), 55)
        frameVisOOC.tooltip = TIP_VIS_OOC

        local frameVisCombat = frameTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Show In Combat"],
            VIS_VALUES, db, "tooltipFrameCombat", function() end), 55)
        frameVisCombat.tooltip = TIP_VIS_COMBAT

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
        local bindVisOOC = bindTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Show Out of Combat"],
            VIS_VALUES, db, "tooltipBindingOutOfCombat", function() end), 55)
        bindVisOOC.tooltip = TIP_VIS_OOC

        local bindVisCombat = bindTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, L["Show In Combat"],
            VIS_VALUES, db, "tooltipBindingCombat", function() end), 55)
        bindVisCombat.tooltip = TIP_VIS_COMBAT

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
        
        -- Migration: Ensure new flat raid settings have defaults.
        -- ☠ The raidFlatGrowthAnchor nil-check alone was DEAD: the Config default seeded
        -- it as the legacy anchor point "TOPLEFT", so it was never nil and never migrated.
        -- GetGrowthAnchorPoint's legacy passthrough made it behave, but "TOPLEFT" is not a
        -- key in growthAnchorOptions, so the dropdown rendered the raw value. The default
        -- is now "START" (Config.lua) and the legacy points are folded in here for
        -- profiles that already stored one. Behaviour-preserving: START and TOPLEFT both
        -- resolve to TOPLEFT, and the END points are exactly what END maps back to.
        local legacyGrowthAnchor = {
            TOPLEFT = "START", BOTTOMLEFT = "END", TOPRIGHT = "END", BOTTOMRIGHT = "END",
        }
        if db.raidFlatGrowthAnchor == nil then
            db.raidFlatGrowthAnchor = "START"
        elseif legacyGrowthAnchor[db.raidFlatGrowthAnchor] then
            db.raidFlatGrowthAnchor = legacyGrowthAnchor[db.raidFlatGrowthAnchor]
        end
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
        -- ⚠ The two grouped-raid sliders USED to be re-labelled here on a direction change
        -- (Groups Per Row <-> Groups Per Column, Row Spacing <-> Column Spacing). They are
        -- now "Groups Before Wrap" and "Wrap Spacing", which describe the wrap rather than
        -- the axis and so do not swap -- and leaving the writes in would have silently
        -- restored the old names the first time anyone touched Growth Direction.
        -- Only the flat grid's slider still names an axis.
        local function UpdateDynamicLabels()
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
            -- ☠ REBUILD THE PAGE, AND IT IS NOT OPTIONAL. Orientation decides both the
            -- dropdown TITLES ("Column Order" vs "Row Order", "Columns Grow From" vs
            -- "Rows Grow From" on the flat grid) AND their VALUES (Left/Right vs
            -- Top/Bottom, per the MAIN/CROSS axis note further down). Both are baked at
            -- build time, so without this rebuild a direction change leaves seven
            -- dropdowns offering the previous orientation's edges until the window is
            -- reopened. ⚠ An earlier comment here claimed the values were static
            -- "Start (Left/Top)" / "End (Right/Bottom)" and only titles needed
            -- refreshing -- true for a while, false again now. Deferred so it runs after
            -- the triggering dropdown's own click handler has finished unwinding.
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
        --
        -- Border and Border Shadow are TWO builders, each taking the group and
        -- parent it should build into, because popout gate two mounts them as two
        -- separate popout rows. Here they are mounted back-to-back into the one
        -- Appearance group, which is the same panel, in the same order, as the
        -- single CreateBorderControls call they replaced.
        --
        -- ⚠ shadowDisableWhen is not decoration. In the single call the shadow
        -- rows greyed with Show Border because CreateBorderControls' own
        -- composition loop reached them; split out, the shadow builder is never
        -- inside that loop, so the same predicate has to be handed to it.
        local function BuildBorderGroup(tools)
            GUI:CreateBorderControls(tools.group, db, "frame", {
                parent       = tools.parent,
                include      = {
                    -- Frame Border is the outer chrome of the unit. It's a
                    -- structural element, not an alert surface, so animations
                    -- don't fit the design — removed in Stage 4.0 after Stage
                    -- 3 used it as a dev playground.
                    inset = true, offset = true, blendMode = true,
                    gradient = true,
                    classColor = true, roleColor = true,
                    alpha = true,
                },
                fullUpdate   = function() UpdateFrames() DF:LightweightUpdateBorder() end,
                lightUpdate  = function() DF:LightweightUpdateBorder() end,
                lightColors  = function() DF:LightweightUpdateBorderColor() end,
                refreshStates = tools.refreshStates,
                sizeMin = 1, sizeMax = 16, sizeStep = 1,
                noShowToggle = tools.hoistToggles or nil,
            })
        end
        local function BuildBorderShadowGroup(tools)
            GUI:CreateBorderShadowControls(tools.group, db, "frame", {
                parent       = tools.parent,
                -- No lightColors: the shadow colour picker commits through
                -- fullUpdate, exactly as it did inside the single call.
                fullUpdate   = function() UpdateFrames() DF:LightweightUpdateBorder() end,
                lightUpdate  = function() DF:LightweightUpdateBorder() end,
                refreshStates = tools.refreshStates,
                hideWhen     = tools.shadowHideWhen,
                disableWhen  = tools.shadowDisableWhen,
                noEnableToggle = tools.hoistToggles or nil,
            })
        end
        local borderTools = {
            group  = appearanceGroup,
            parent = self.child,
            refreshStates = function() if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end end,
            shadowDisableWhen = function() return db.frameShowBorder == false end,
        }
        BuildBorderGroup(borderTools)
        BuildBorderShadowGroup(borderTools)
        Add(appearanceGroup, nil, 2)

        -- ===== FRAME FADE GROUP (Column 2) =====
        -- Whole-frame base opacity, multiplied with the range / health fades
        -- (DF:GetFrameBaseAlpha, ElementAppearance). One global slider, or -- with the
        -- split on -- an out-of-combat and an in-combat value, plus a hover option that
        -- shows the in-combat value while the mouse is on a frame out of combat.
        local frameFadeGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameFadeGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Fade"]), 40)
        local function RefreshFrameFade()
            if DF.InvalidateHealthFadeCurve then DF:InvalidateHealthFadeCurve() end
            -- Pets re-apply their fade only on a range-cache miss; flush it so the
            -- next tick picks up the new base instead of waiting for a range change.
            if DF.ClearRangeCache then DF:ClearRangeCache() end
            DF:RefreshAllVisibleFrames()
            if DF.UpdateAllFrameAppearances then DF:UpdateAllFrameAppearances() end
        end
        local ffGlobal = frameFadeGroup:AddWidget(GUI:CreateSlider(self.child, L["Global Frame Fade"], 0.1, 1.0, 0.05, db, "frameFadeAlpha", nil, RefreshFrameFade, true), 55)
        ffGlobal.hideOn = function(d) return d.frameFadeSplitCombat end
        ffGlobal.tooltip = L["Opacity of every unit frame. Multiplies with the out-of-range and health fades."]
        frameFadeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Separate Combat Fade"], db, "frameFadeSplitCombat", function()
            self:RefreshStates()
            RefreshFrameFade()
        end), 30)
        local ffOOC = frameFadeGroup:AddWidget(GUI:CreateSlider(self.child, L["Out of Combat Frame Fade"], 0.1, 1.0, 0.05, db, "frameFadeAlphaOutOfCombat", nil, RefreshFrameFade, true), 55)
        ffOOC.hideOn = function(d) return not d.frameFadeSplitCombat end
        ffOOC.tooltip = L["Frame opacity while you are out of combat. The preview shows this value while you configure it."]
        local ffCombat = frameFadeGroup:AddWidget(GUI:CreateSlider(self.child, L["In Combat Frame Fade"], 0.1, 1.0, 0.05, db, "frameFadeAlphaInCombat", nil, RefreshFrameFade, true), 55)
        ffCombat.hideOn = function(d) return not d.frameFadeSplitCombat end
        local ffInstance = frameFadeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use In-Combat Fade In Instances"], db, "frameFadeInstanceUsesCombat", RefreshFrameFade), 30)
        ffInstance.disableOn = function(d) return not d.frameFadeSplitCombat end
        ffInstance.tooltip = L["Inside dungeons, raids, arenas and battlegrounds the frames hold the in-combat opacity the whole visit — no fading out between pulls."]
        local ffHover = frameFadeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show In-Combat Fade When Hovering"], db, "frameFadeHoverUsesCombat", RefreshFrameFade), 30)
        ffHover.disableOn = function(d) return not d.frameFadeSplitCombat end
        ffHover.tooltip = L["Out of combat, a frame under the mouse uses the in-combat opacity so you can still read and interact with it."]
        local ffHoverScope = frameFadeGroup:AddWidget(GUI:CreateDropdown(self.child, L["Hover Applies To"], {
            ALL   = L["All Frames"],
            FRAME = L["Hovered Frame Only"],
        }, db, "frameFadeHoverScope", RefreshFrameFade), 55)
        ffHoverScope.disableOn = function(d) return not d.frameFadeSplitCombat or not d.frameFadeHoverUsesCombat end
        ffHoverScope.tooltip = L["All Frames lifts every unit frame while the mouse is on any of them, so the whole group is readable and clickable."]
        Add(frameFadeGroup, nil, 2)


        -- ===== LAYOUT DIRECTION GROUP (Column 1) =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout Direction"]), 40)
        
        -- ☠☠ TWO DROPDOWNS, AND THE RAID+GROUPS ONE IS *DELIBERATELY* THE INVERSE.
        -- DO NOT "unify" them again. That was tried (be7e61e1) and it is the regression
        -- this comment exists to prevent.
        --
        -- Rows and Columns name THE SHAPE OF THE REPEATING UNIT -- the thing you can see:
        --   * party / flat raid: the unit is a line of frames. HORIZONTAL lays them
        --     left-to-right (party sets point="LEFT" + xOffset, Headers.lua ~1140), so
        --     HORIZONTAL = "Rows".
        --   * grouped raid: the unit is a GROUP, and HORIZONTAL builds each group as a
        --     vertical stack of five (groupHeight = 5*frameHeight + 4*spacing) while
        --     running the groups across. What you see is COLUMNS. So here the pair is
        --     inverted, and that is correct, not a bug.
        --
        -- ⚠ This is the convention the rest of the game uses, verified in source, not
        -- assumed: Blizzard's own raid option is "Horizontal Groups", and with it on
        -- CompactRaidGroup_UpdateLayout anchors each member LEFT->RIGHT off the previous
        -- one, i.e. horizontal describes the GROUP, not the arrangement of groups. Grid2
        -- says "Horizontal groups" for the same thing and its SetOrientation(horizontal)
        -- sets the header's xOffset, so again the group is the row. (ElvUI sidesteps the
        -- word entirely with "Down and then Right" style pairs.)
        -- ⇒ DandersFrames' internal HORIZONTAL/VERTICAL are the INVERSE of that
        -- convention for grouped raid. The labels have to absorb that; the keys cannot
        -- be renamed without a migration.
        --
        -- The history, so nobody re-derives it: three dropdowns originally, the
        -- raid+groups one inverted as above and correct. Aphoex (2026-08-14) reported
        -- "choosing columns enables rows configuration, and viceversa" -- real, but it
        -- was a COLLISION, not an inversion: "Columns" names the group's shape while
        -- "Groups Per Row" names the arrangement of groups, and both are true at once.
        -- Collapsing the dropdowns onto the party reading "fixed" that by making the
        -- grouped dropdown disagree with the frames instead, so "Growth Direction = Rows"
        -- drew columns (Krathe, 2026-08-17). The tooltips below carry the disambiguation
        -- that report actually needed.
        -- ☠ _order OR IT SORTS ALPHABETICALLY BY DISPLAY TEXT. Every directional dropdown
        -- on this page needs it: without _order, CreateDropdown falls back to sorting on
        -- the visible string, so a Top/Bottom pair lists as "Bottom, Top" and reads as
        -- inverted before you have even opened it (Krathe, 2026-08-17). It survived this
        -- long only because "Start (Left/Top)" / "End (Right/Bottom)" sorted E-then-S,
        -- which was equally arbitrary but nobody expects an order from those.
        local growOptions = { _order = { "HORIZONTAL", "VERTICAL" }, HORIZONTAL = L["Rows"], VERTICAL = L["Columns"] }
        local growDrop = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
        growDrop.hideOn = function() return GUI.SelectedMode == "raid" and db.raidUseGroups end
        growDrop.tooltip = L["The shape each line of frames takes. Rows run left to right, Columns run top to bottom."]

        -- Grouped raid: same key, inverted labels, because the repeating unit is a group.
        local groupGrowOptions = { _order = { "HORIZONTAL", "VERTICAL" }, HORIZONTAL = L["Columns"], VERTICAL = L["Rows"] }
        local groupGrowDrop = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], groupGrowOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
        groupGrowDrop.hideOn = function() return not (GUI.SelectedMode == "raid" and db.raidUseGroups) end
        groupGrowDrop.tooltip = L["The shape each raid group takes. Columns stack the five players downward and run the groups across; Rows lay them out sideways and stack the groups down.\n\nThe 'Groups Before Wrap' setting below counts the GROUPS, not the players."]

        -- ☠ THE OVERRIDE READOUT MUST SPEAK THE GLOBAL'S DIALECT. These two dropdowns
        -- share ONE key with OPPOSITE label maps, so the word for a given stored value
        -- depends on raidUseGroups -- and an auto layout can override raidUseGroups. An
        -- auto layout with groups OFF, against a global with groups ON, therefore printed
        -- the global's growth direction through the FLAT map: "(Global: Columns)" beside a
        -- global page reading "Rows". Same value, wrong dialect, and it reads as the addon
        -- being wrong about a setting the user can see for themselves.
        -- ⚠ 2026-08-26: this used to describe a RESOLVER that "picks the map from the
        -- GLOBAL raidUseGroups". No such thing ships. That was one of three widget-level
        -- attempts, all reverted -- two of which silently never fired -- and the sentence
        -- outlived the code it described. What actually happens: the PROFILE LAYER hands
        -- back a growDirection already expressed in this profile's mode
        -- (AutoProfilesUI:GetGlobalValue / GetRuntimeGlobalValue), so by the time a label
        -- map is applied here there is only one dialect left and no map-picking to do.
        -- ☠ Do not re-add a widget-side translation: with the source translating, a second
        -- pass here inverts it straight back.
        -- ⚠ Nothing in the profile layer changes what is STORED or drawn -- only the
        -- the global. The label flip when you toggle the checkbox is not this bug and is
        -- deliberate: the same value genuinely renders as rows in one mode and columns in
        -- the other, so the word has to change with it (see the convention note above).
        -- ⚠ NO OVERRIDE HOOKS HERE, DELIBERATELY. growDirection is mode-relative and a
        -- layout can override the key that sets its mode, so a flat layout matching a
        -- grouped global stores the OPPOSITE raw value -- which made the override row
        -- report a difference the user does not have. Three widget-level attempts to
        -- describe or suppress that did not hold; the answer lives in the profile layer
        -- instead (AutoProfilesUI:GetGlobalValue / IsSettingOverridden translate
        -- growDirection into the editing profile's mode), so the dot, the reset, the
        -- readout and the tab stars all get one consistent answer with no widget
        -- plumbing. Do not re-add a per-dropdown hook: it would translate twice.

        -- ☠ EVERY Start/End PAIR ON THIS PAGE SITS ON ONE OF TWO PERPENDICULAR AXES,
        -- AND WHICH ONE IS NOT GUESSABLE FROM THE CONTROL'S NAME. Get this wrong and the
        -- dropdown confidently offers "Right" for something that only ever moves up and
        -- down -- which is precisely how "Rows Grow From is broken" got reported.
        --   MAIN  = the axis Growth Direction names.        HORIZONTAL -> Left/Right
        --   CROSS = the perpendicular one, where things wrap. HORIZONTAL -> Top/Bottom
        -- The assignments, all verified against the positioners (not against the names):
        --   MAIN  : growthAnchor (party frames), raidGroupAnchor (the group block),
        --           raidFlatGrowthAnchor (the grid), raidFlatFrameAnchor (flat players,
        --           which fill ALONG the main axis)
        --   CROSS : raidGroupRowGrowth (extra rows of groups), raidPlayerAnchor (grouped
        --           players, which stack ACROSS the main axis inside their group),
        --           raidFlatColumnAnchor (where the grid wraps)
        -- ⚠ The two "Players Grow From" controls are on OPPOSITE axes -- flat fills along,
        -- grouped stacks across. Same label, same START/END values, different direction.
        -- These were all flattened to one orientation-free "Start (Left/Top)" /
        -- "End (Right/Bottom)" pair by a wording pass; the page already rebuilds on a
        -- direction change (OnGrowthDirectionChanged), which is what lets them be live.
        local isVert = db.growDirection == "VERTICAL"
        local MAIN_START  = isVert and L["Top"]  or L["Left"]
        local MAIN_END    = isVert and L["Bottom"] or L["Right"]
        local CROSS_START = isVert and L["Left"] or L["Top"]
        local CROSS_END   = isVert and L["Right"] or L["Bottom"]

        -- Growth anchor (party only)
        local anchorOptions = { _order = { "START", "CENTER", "END" }, START= MAIN_START, CENTER= L["Center"], END= MAIN_END }
        local anchorDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Frames Grow From"], anchorOptions, db, "growthAnchor", UpdateFrames), 55)
        anchorDropdown.hideOn = function() return GUI.SelectedMode == "raid" end
        
        Add(layoutGroup, nil, 1)
        
        -- ===== RAID LAYOUT MODE GROUP (Column 1, raid only) =====
        local raidModeGroup = GUI:CreateSettingsGroup(self.child, 280)
        raidModeGroup:AddWidget(GUI:CreateHeader(self.child, L["Raid Layout Mode"]), 40)
        raidModeGroup.hideOn = function() return GUI.SelectedMode ~= "raid" end
        
        raidModeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use Group-Based Layout"], db, "raidUseGroups", function()
            -- ☠☠ KEEP THE LAYOUT THE USER CAN SEE, NOT THE VALUE UNDER IT. growDirection
            -- is ONE key meaning OPPOSITE things in the two modes -- flat HORIZONTAL lays
            -- frames left-to-right (rows), grouped HORIZONTAL stacks each group five deep
            -- and runs the groups across (columns) -- which is why the two dropdowns carry
            -- inverted labels. Correct as descriptions, but it meant TOGGLING THIS BOX
            -- SILENTLY RE-ORIENTED THE RAID: sitting on "Rows" in grouped mode and turning
            -- groups off left the stored VERTICAL intact, which flat renders as columns,
            -- and the dropdown honestly relabelled itself "Columns". The user then had to
            -- set it back to "Rows" to get what they already had (Krathe, 2026-08-25).
            --
            -- The maps are exact inverses, so preserving the LABEL is inverting the VALUE.
            -- Rows stay rows, columns stay columns, and the box goes back to meaning only
            -- what it says: whether players are organised into groups.
            -- ⚠ Writes through `db`, so an auto layout in edit mode records it as an
            -- override alongside raidUseGroups -- which is right: expressing "flat, in
            -- rows" needs both keys, and storing only the toggle would re-orient the raid
            -- whenever the layout activated.
            -- ⚠ BEFORE UpdateFrames, or the pass below lays out on the pre-flip value.
            -- (The real cure is splitting the key per mode so nothing has to be flipped;
            -- that is a migration plus ~99 read sites and is deliberately not this fix.)
            db.growDirection = (db.growDirection == "HORIZONTAL") and "VERTICAL" or "HORIZONTAL"
            UpdateFrames()
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
        
        -- Six controls, four of them directional, and their labels already swap with the
        -- growth direction -- so the tooltips have to swap with it too, or half of them
        -- describe the other orientation. The page rebuilds on a direction change
        -- (OnGrowthDirectionChanged), which is what keeps these in step. isVert and the
        -- MAIN_/CROSS_ edge words are declared once with the anchor options above.
        local groupSpacingSlider = groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Group Spacing"], -5, 100, 1, db, "raidGroupSpacing", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
        groupSpacingSlider.tooltip = isVert and L["Gap between one group and the next down the same column."]
            or L["Gap between one group and the next along the same row."]

        -- ⚠ "Row Spacing" and "Groups Per Row" are gone, and not for tidiness. With the
        -- Growth Direction dropdown above reading "Columns" in horizontal mode, a box that
        -- then said Row three times was the exact collision Aphoex reported -- "Columns"
        -- names the group's shape, "Row" named the arrangement of groups, both true at
        -- once. These two are the last places the word appeared in the second sense, so
        -- they now describe the WRAP instead, and Row/Column means one thing on this page.
        -- They also stop swapping with the orientation, because wrapping is wrapping.
        rowColSpacingSlider = groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Wrap Spacing"], -5, 100, 1, db, "raidRowColSpacing", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
        rowColSpacingSlider.tooltip = isVert and L["Gap between one column of groups and the column beside it."]
            or L["Gap between one row of groups and the row below it."]

        -- ☠ THIS SLIDER GATES THE ANCHOR GRID'S BOTTOM ROW, SO IT HAS TO REFRESH IT.
        -- RefreshChildStates is what re-runs a child's disableOn and refreshContent, and
        -- nothing calls it on a slider change -- CreateCheckbox self-calls it on toggle,
        -- sliders never did. So moving 8 -> 7 left the wrap cells hidden until some
        -- unrelated control was touched: the grid was correct, it had just never been
        -- asked again. (This bit the old Row Order disableOn identically; it only became
        -- visible once the gate had something to re-enable.)
        local function UpdateFramesAndGates()
            UpdateFrames()
            if groupLayoutGroup.RefreshChildStates then groupLayoutGroup:RefreshChildStates() end
        end
        groupsPerRowSlider = groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Groups Before Wrap"], 1, 8, 1, db, "raidGroupsPerRow", UpdateFramesAndGates, function()
            DF:LightweightUpdateRaidLayout()
            if groupLayoutGroup.RefreshChildStates then groupLayoutGroup:RefreshChildStates() end
        end, true), 55)
        groupsPerRowSlider.tooltip = isVert and L["How many groups sit in a column before a new column starts. At 8, every group shares one column."]
            or L["How many groups sit on a row before a new row starts. At 8, every group shares one row."]

        -- ☠ ONE CORNER PICKER, REPLACING "Groups Grow From" + "Row Order". Do not split
        -- them back apart. They were two axes of one question -- which corner of the
        -- reserved area does the block sit in -- asked in two vocabularies, three controls
        -- apart, and nobody read them as one thing (Aphoex 2026-08-14, Krathe 2026-08-17).
        --
        -- raidGroupAnchor is the horizontal half (START/CENTER/END), raidGroupRowGrowth the
        -- vertical (START/END). Both keys, values and defaults are UNCHANGED -- this is a
        -- widget swap, so no migration and nothing to do for existing profiles.
        --
        -- ⚠ The vertical half is inert whenever there is only one row of groups, which is
        -- the case at the default Groups Before Wrap = 8: both positioners flip the row
        -- index as `rcIdx = (fullGridRC - 1) - rcIdx` over `ceil(8 / groupsPerRow)`, so at
        -- 8 the flip is the identity. The grid hides its wrap cells there rather than
        -- offering a choice that cannot land -- and it does NOT write the key, so a stored
        -- END survives and comes back the moment the slider drops below 8.
        -- ⚠ NOT clamped to the POPULATED group count either. The flip is deliberately over
        -- the full eight-group grid, so with five groups at four per row the bottom cell
        -- legitimately moves them to the bottom of that grid, not of the populated rows.
        local groupAnchorGrid = groupLayoutGroup:AddWidget(
            -- ⚠ Plain UpdateFramesAndGates again. The pin toggle used to be a separate
            -- row whose hideOn only a page layout pass could re-evaluate, so a cell click
            -- that changed the centre-ness had to force GUI:RefreshCurrentPage or the
            -- checkbox appeared a click late. The toggle now lives inside this widget and
            -- its own Refresh runs on every cell click, so that machinery is gone.
            GUI:CreateAnchorGrid(self.child, L["Groups Anchor"], db, "raidGroupAnchor", "raidGroupRowGrowth", UpdateFramesAndGates, {
                verticalInertFn = function(d) return (d.raidGroupsPerRow or 8) >= 8 end,
                -- ☠ In Rows growth the two keys swap screen axes -- raidGroupAnchor moves
                -- things UP/DOWN there and raidGroupRowGrowth moves them LEFT/RIGHT, the
                -- exact transpose of Columns growth. Without this the grid draws a corner
                -- that is 90 degrees from where the frames land.
                transposedFn = function(d) return d.growDirection == "VERTICAL" end,
                -- ☠ Players Grow From = End mirrors the WRAP axis (the group anchors to the
                -- far corner and the wrap offset is measured back from it), so the grid has
                -- to translate or it names the wrong side. Decoupling them in the
                -- positioners would move existing users' frames, which is not on the table.
                --
                -- ⚠ With Pin Main Group on, the meaning of the wrap cell CHANGES: the main
                -- group is nailed to the anchor, so the only directional thing a user can
                -- see is which side the OVERFLOW extends — the cell must name that side or
                -- it reads as wrong (Krathe, 2026-08-18: "Center Left" with overflow going
                -- right). Overflow sits opposite the main unit, and the main unit's screen
                -- side is (playersEnd == wrapEnd), so displayed-side == overflow-side works
                -- out to mirroring exactly when players is START — the inverse of the
                -- unpinned rule. Derived against WrapKey's involution in Widgets.lua, not
                -- assumed; the geometry itself never changes, only the translation.
                wrapMirroredFn = function(d)
                    local playersEnd = (d.raidPlayerAnchor or "START") == "END"
                    if (d.raidGroupCenterMode or "ALL") == "MAIN" and (d.raidGroupAnchor or "START") == "CENTER" then
                        return not playersEnd
                    end
                    return playersEnd
                end,
            }))
        -- The non-obvious half is the empty space: the frame area is sized for all EIGHT
        -- groups so the drag box never resizes under you, so in a five-group raid the left
        -- corners leave three groups' worth of gap on the right. That gap is what made the
        -- old dropdown look broken when it was in fact the only one of the two doing
        -- anything.
        groupAnchorGrid.tooltip = L["Which corner of the frame area the groups start from, and which way they fill. The area is always sized for all eight groups, so the unused space falls on the opposite side."]

        -- ☠ ITS OWN ROW, AND GREYED -- NEVER HIDDEN. Four arrangements have been tried and
        -- this is the one that survives: flush row, indented row, a schematic, and finally
        -- inline inside the picker beside the cells. The inline version broke on the
        -- TRANSPOSE -- Rows growth draws the grid 2 wide x 3 tall instead of 3 x 2, so the
        -- space the toggle sat in changes shape and it no longer lines up with anything
        -- (Krathe, 2026-08-18).
        --
        -- ⚠ disableOn covers BOTH conditions and there is no hideOn. A control that
        -- vanishes when it does not apply cannot be discovered, and it made the rows below
        -- jump as the anchor or the wrap slider changed. (The anchor grid is the one
        -- exception: it HIDES its inert wrap cells, because at 8 before wrap there really
        -- is only one row of slots and an empty dim cell read as selectable -- see
        -- GUI:CreateAnchorGrid. That is a picker of positions, not a control that can be
        -- discovered by its label, so the rule here does not apply to it.)
        --
        -- ⚠ The callback must reposition the CONTAINER as well as the frames -- half of
        -- this setting is a container anchor-reference shift, consumed only in
        -- DF:UpdateRaidContainerPosition -- AND refresh the picker, because the meaning of
        -- its wrap cell flips with this toggle (see wrapMirroredFn above).
        local function UpdatePinMainGroup()
            UpdateFrames()
            if DF.UpdateRaidContainerPosition then DF:UpdateRaidContainerPosition() end
            if groupAnchorGrid and groupAnchorGrid.Refresh then groupAnchorGrid:Refresh() end
        end
        -- ☠ A STRING KEY, NOT THE BOOLEAN THIS REPLACED. A dropdown writes an option key,
        -- and mapping string <-> boolean through customGet/customSet would have fed the
        -- STRING into two AutoProfiles paths that take dbKey verbatim (HandleRuntimeWrite
        -- and SetProfileSetting). An override of "ALL" is truthy, so it would have
        -- switched the pin ON where it means OFF. raidGroupPinMainGroup never shipped, so
        -- the type change costs no migration.
        -- ⚠ The labels are deliberately bare -- the tooltip carries the meaning. "Default"
        -- reuses the existing shared string; the key values stay ALL/MAIN so the geometry
        -- and the saved setting are unaffected by any future relabelling.
        local centerModeOptions = { _order = { "ALL", "MAIN" },
            ALL = L["Default"], MAIN = L["Fixed"] }
        local centerModeDrop = groupLayoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Center Mode"], centerModeOptions, db, "raidGroupCenterMode", UpdatePinMainGroup), 55)
        centerModeDrop.disableOn = function(d)
            d = d or db
            return (d.raidGroupAnchor or "START") ~= "CENTER" or (d.raidGroupsPerRow or 8) >= 8
        end
        centerModeDrop.tooltip = L["What happens when your groups wrap onto more than one row. Needs Groups Anchor on a centre position.\n\nDefault: all groups stay centred together, so they shift sideways as the raid fills up.\n\nFixed: the first groups stay put, and extra groups appear to one side of them."]

        -- Players Grow From = the direction players fill the group's main axis.
        -- HORIZONTAL groups stack players vertically (Top/Bottom); VERTICAL groups
        -- stack players horizontally (Left/Right). Values map to START/END. CROSS axis.
        local playerAnchorOptions = { _order = { "START", "END" }, START= CROSS_START, END= CROSS_END }
        -- ☠ FLIPPING THIS MUST NOT MOVE THE BLOCK, AND THAT IS WHY IT WRITES TWO KEYS.
        -- raidPlayerAnchor mirrors the WRAP axis in the positioners (the group anchors to
        -- the far corner and the wrap offset is measured back from it), so changing it
        -- slid the whole raid to the other end of the reserved grid -- a control named
        -- "Players Grow From" reaching well outside a group. Decoupling them in the
        -- positioners would move existing users' frames and is not on the table, so the
        -- compensation lives here: invert the stored wrap key at the same moment, and the
        -- corner Groups Anchor names stays exactly where it was while only the gap inside
        -- a partial group moves. The two controls become independent from the user's side
        -- without a single line of geometry changing.
        --
        -- ⚠ ONLY WHEN THE WRAP AXIS CAN BE SEEN. At 8 before wrap there is one row, the
        -- mirror has nowhere to move anything, and inverting the key would silently flip a
        -- value whose effect only appears later when the slider drops below 8.
        -- ⚠ A write triggered by another write is a pattern this addon has been bitten by
        -- three times, so: this runs ONLY from this dropdown's own click handler. It never
        -- fires at load, on a profile switch or on import, so no existing setup changes on
        -- its own -- which is the whole reason it is safe to do here and not in a migration.
        local function SetPlayerAnchorKeepingBlock(v)
            local prev = db.raidPlayerAnchor or "START"
            db.raidPlayerAnchor = v
            if prev ~= v and (db.raidGroupsPerRow or 8) < 8 then
                db.raidGroupRowGrowth = (db.raidGroupRowGrowth == "END") and "START" or "END"
            end
        end
        -- ⚠ The auto-profile RUNTIME path skips customSet: CreateDropdown redirects the
        -- write to the baseline and returns before it. The compensation still has to
        -- happen there, or the baseline keeps the old wrap key and its block slides the
        -- moment the overlay lifts. It is applied to the baseline ONLY when the wrap key
        -- is itself overridden (HandleRuntimeWrite then lands it on the baseline and the
        -- live overlay is untouched); when the wrap key is live, flipping it would move
        -- the LIVE block under an unchanged live player anchor, which is the exact thing
        -- this compensation exists to prevent -- so that half is deliberately left alone.
        local function PlayerAnchorRuntimeWrite(v, prevGlobal)
            local AP = DF.AutoProfilesUI
            if not AP or (prevGlobal or "START") == v then return end
            local base = DF._realRaidDB
            if not base or (base.raidGroupsPerRow or 8) >= 8 then return end
            if AP.IsOverriddenByRuntime and AP:IsOverriddenByRuntime("raidGroupRowGrowth") then
                AP:HandleRuntimeWrite("raidGroupRowGrowth",
                    (base.raidGroupRowGrowth == "END") and "START" or "END")
            end
        end
        -- ⚠ UpdateFramesAndGates, not UpdateFrames: this rewrites the wrap key, so the
        -- anchor grid has to be re-asked or it keeps showing the pre-flip corner.
        local playerAnchorDrop = groupLayoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Players Grow From"], playerAnchorOptions, db, "raidPlayerAnchor", UpdateFramesAndGates, nil, SetPlayerAnchorKeepingBlock,
            { onRuntimeWrite = PlayerAnchorRuntimeWrite }), 55)
        playerAnchorDrop.tooltip = L["Which end of a group its players fill from. A group with fewer than five players leaves its empty space at the opposite end."]
        
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
        
        -- ☠ CROSS axis, NOT main -- these labels were MAIN_* and lied. GetGrowthAnchorPoint
        -- pins innerContainer to a CORNER of raidContainer, and the block always matches
        -- the container on the main axis (it is playersPerRow wide in Rows, five tall in
        -- Columns), so only the cross component can move: END is BOTTOMLEFT in Rows and
        -- TOPRIGHT in Columns. With MAIN_* the dropdown offered "Right" for Rows and moved
        -- the grid DOWN. The sibling below is also cross-axis and that is not a duplicate:
        -- this one ALIGNS the block in the reserved space, that one picks which end rows
        -- stack FROM.
        local growthAnchorOptions = { _order = { "START", "CENTER", "END" }, START= CROSS_START, CENTER= L["Center"], END= CROSS_END }
        flatGridGroup:AddWidget(GUI:CreateDropdown(self.child, L["Grid Alignment"], growthAnchorOptions, db, "raidFlatGrowthAnchor", UpdateFrames), 55)

        -- Columns/Rows Grow From = the direction the grid wraps (secondary axis).
        -- VERTICAL (Columns) wraps left/right; HORIZONTAL (Rows) wraps top/bottom.
        local flatColumnLabel = db.growDirection == "VERTICAL" and L["Columns Grow From"] or L["Rows Grow From"]
        local flatColumnOptions = { _order = { "START", "END" }, START= CROSS_START, END= CROSS_END }
        flatGridGroup:AddWidget(GUI:CreateDropdown(self.child, flatColumnLabel, flatColumnOptions, db, "raidFlatColumnAnchor", UpdateFrames), 55)

        -- Players Grow From = the direction players fill the grid's main axis.
        -- HORIZONTAL (Rows) fills Left/Right; VERTICAL (Columns) fills Top/Bottom.
        -- Replaces the old "Reverse Order" checkbox; START/END values are identical.
        -- ⚠ MAIN axis -- the OPPOSITE of the grouped Players Grow From, which is CROSS.
        local flatFillOptions = { _order = { "START", "END" }, START= MAIN_START, END= MAIN_END }
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
