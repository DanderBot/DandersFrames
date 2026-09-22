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
        -- CreateLink is fixed-layout, so hand it the group's inner width up front --
        -- its wrapped height is then known before AddWidget (the group advances Y by
        -- the height we pass).
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
            -- Snapped gap: the row is a CHAIN (Copy <- Sync <- Reset), so the offset
            -- itself has to be a whole number of device pixels or every button to the
            -- left of this one inherits the fraction.
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
                            -- It ended in FullProfileRefresh, which already rebuilt this page.
                            if GUI.RefreshCurrentPageAfterFullRefresh then GUI.RefreshCurrentPageAfterFullRefresh() elseif GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
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
                                    -- It ended in FullProfileRefresh, which already rebuilt this page.
                                    if GUI.RefreshCurrentPageAfterFullRefresh then GUI.RefreshCurrentPageAfterFullRefresh() elseif GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
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
                            -- It ended in FullProfileRefresh, which already rebuilt this page.
                            if GUI.RefreshCurrentPageAfterFullRefresh then GUI.RefreshCurrentPageAfterFullRefresh() elseif GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end)

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

    -- Define category order
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

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: ONE 280 box in column 1 headed
        -- "Frame Display", holding all six controls in their original order.
        --
        -- MODERN is the Debuff Bar's collapsible-card design: one card per
        -- group, two settings per row inside a card wide enough, dim captions,
        -- the value summary in a shut card's corner, Expand All / Collapse All
        -- at the top.
        --
        -- ☠ MODERN SPLITS THE CLASSIC BOX IN TWO, because it was never one
        -- feature. Solo Mode plus the three rested controls is a GATED group --
        -- turn Solo Mode off and none of them do anything, which is exactly what
        -- their own disableOn predicates already say -- so Solo Mode is that
        -- card's header tick. "Hide Self from Party Frames" is an INDEPENDENT
        -- tick that works whether or not you ever play solo, so it cannot go
        -- behind that gate: it keeps the box's own name, "Frame Display", as a
        -- card of its own.
        --
        --   column 1   Solo Mode       (tick: soloMode)
        --   column 2   Frame Display   (Hide Self from Party Frames)
        --
        -- Both are behaviour, so neither is pinnable, and the two columns are
        -- balanced rather than split by behaviour/looks.
        --
        -- ⚠ THE PAGE IS partyOnly (set just below this builder) and every widget
        -- here carries its own raid hideOn. Both are kept exactly as they were:
        -- the tab is never reachable in raid mode, and the per-widget guards are
        -- the belt that has always been there.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery. Its PROLOGUE closes any panel a previous
        -- build left standing and retires that build's holders, and it carries the
        -- section helper the card pages build with. nil in classic, which is what
        -- the `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE SECTION: the Debuff Bar's helper (tools.OpenSection) and its two
        -- opt-ins, which every card here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ===== SOLO MODE (the top of the classic box, the first card) =====
        -- Verbatim, taking the group and parent it should build into: same
        -- factories, same L keys, same db keys, same callbacks, same slot
        -- heights, same hideOn/disableOn. Guarded by
        -- test_visibility_page_builders.lua, which reads this body out of the
        -- source and checks it against the inventory it had inline.
        --
        -- ⚠ THE COMPOUND disableOn PREDICATES ARE UNCHANGED, including the
        -- "not d.soloMode" half. Classic has no header tick and needs that half;
        -- in the card it is what greys the three rested controls while the tick
        -- is off. One builder serving both is what stops the two drifting.
        local function BuildSoloModeGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the card's HEADER carries this tick. Still built in
            -- classic, where it is the group's only on/off control.
            if not tools2.hoistToggle then
                local soloMode = group:AddWidget(GUI:CreateCheckbox(parent, L["Solo Mode"], db, "soloMode", function()
                    DF:UpdateAllFrames()
                    DF:UpdateDefaultPlayerFrame()
                end), 30)
                soloMode.hideOn = function() return GUI.SelectedMode == "raid" end
            end

            local restedIndicator = group:AddWidget(GUI:CreateCheckbox(parent, L["Rested Indicator"], db, "restedIndicator", function()
                DF:UpdateRestedIndicator()
            end), 30)
            restedIndicator.hideOn = function() return GUI.SelectedMode == "raid" end
            restedIndicator.disableOn = function(d) return not d.soloMode end
            restedIndicator.tooltip = L["Show rested indicators when in a rested area (inn, city)."]

            local restedIcon = group:AddWidget(GUI:CreateCheckbox(parent, L["    Show ZZZ Icon"], db, "restedIndicatorIcon", function()
                DF:UpdateRestedIndicator()
            end), 30)
            restedIcon.hideOn = function() return GUI.SelectedMode == "raid" end
            restedIcon.disableOn = function(d) return not d.soloMode or not d.restedIndicator end
            restedIcon.tooltip = L["Show the animated ZZZ icon on the player frame."]

            local restedGlow = group:AddWidget(GUI:CreateCheckbox(parent, L["    Show Frame Glow"], db, "restedIndicatorGlow", function()
                DF:UpdateRestedIndicator()
            end), 30)
            restedGlow.hideOn = function() return GUI.SelectedMode == "raid" end
            restedGlow.disableOn = function(d) return not d.soloMode or not d.restedIndicator end
            restedGlow.tooltip = L["Show a pulsing yellow glow around the frame."]

            local soloNote = group:AddWidget(GUI:CreateLabel(parent, L["Solo Mode: Show your player frame when not in a group."], 250), 30)
            soloNote.hideOn = function() return GUI.SelectedMode == "raid" end
        end

        -- ===== HIDE SELF FROM PARTY FRAMES (the foot of the classic box, the
        -- Frame Display card in Modern) =====
        -- ⚠ THE CALLBACK IS VERBATIM AND MUST STAY SO: it writes a SECURE header
        -- attribute, which is why it is gated on InCombatLockdown before it
        -- touches showPlayer. Named at page scope so there is one copy of a body
        -- that writes a secure attribute.
        local function ApplyHideSelf()
            -- Update the secure header's showPlayer attribute
            if not InCombatLockdown() and DF.partyHeader then
                DF.partyHeader:SetAttribute("showPlayer", not db.hidePlayerFrame)
            end
            -- Reapply header settings to reposition frames
            if DF.ApplyHeaderSettings then
                DF:ApplyHeaderSettings()
            end
            DF:UpdateAllFrames()
        end

        local function BuildHideSelfGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local hidePlayer = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Self from Party Frames"], db, "hidePlayerFrame", ApplyHideSelf), 30)
            hidePlayer.hideOn = function() return GUI.SelectedMode == "raid" end
            hidePlayer.tooltip = L["Removes your player frame from the DandersFrames party display."]
        end

        if classicLayout then
            -- ===== FRAME DISPLAY GROUP (Column 1) =====
            -- One box, both builders, in the order the six controls always had.
            local frameDisplayGroup = GUI:CreateSettingsGroup(self.child, 280)
            frameDisplayGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Display"]), 40)
            BuildSoloModeGroup({
                group = frameDisplayGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            BuildHideSelfGroup({
                group = frameDisplayGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(frameDisplayGroup, nil, 1)
        else
            -- The summary, per the sweep's convention: at most four items, a
            -- fixed order, "\194\183" between them, WORDS localised and numbers
            -- raw, every read guarded because a profile mid-migration may be
            -- missing any of these keys. The header tick already says whether
            -- Solo Mode is on (a shut card reads "Off" while it is not), so the
            -- summary is about the one thing BEHIND it -- the rested indicator
            -- and how it is drawn.
            --
            -- ⚠ NOTHING IS INVENTED. "Rested Indicator" is the checkbox's own
            -- label, and "Icon" / "Glow" are single words the locale already
            -- ships -- the two sub-ticks' own labels carry the indent that pins
            -- them under their parent and are far too long for a summary line.
            local function SoloModeSummary(d)
                if not d then return "" end
                if not d.restedIndicator then return "" end
                local parts = { L["Rested Indicator"] }
                if d.restedIndicatorIcon then parts[#parts + 1] = L["Icon"] end
                if d.restedIndicatorGlow then parts[#parts + 1] = L["Glow"] end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Buff Bar's placement and its reasons: they act on cards in both
            -- columns, and "both" carries them through the one-column fold intact.
            Add(tools.SectionControls(self.child), 24, "both")

            -- ☠ SOLO MODE IS THE HEADER'S TICK, so the builder is told not to
            -- build its own (hoistToggle). The commit is what the in-body
            -- checkbox ran plus the state pass that greys the three rested
            -- controls -- never a page rebuild. Decides whether a solo frame
            -- exists at all, so no pin.
            local soloBand = OpenSection(L["Solo Mode"], "visibility_solo", 1, SoloModeSummary, nil, nil, nil, {
                db = db, key = "soloMode", label = L["Solo Mode"],
                onChanged = function()
                    DF:UpdateAllFrames()
                    DF:UpdateDefaultPlayerFrame()
                    self:RefreshStates()
                end,
            })
            BuildSoloModeGroup({
                group = soloBand, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(soloBand)

            -- ☠ HIDE SELF KEEPS THE BOX'S NAME, as a card of its own. It is what
            -- is left of "Frame Display" once Solo Mode has its own card, and it
            -- is not behind Solo Mode's gate and never was. No tick: the one
            -- checkbox IS the setting. Behaviour, so no pin.
            local displayBand = OpenSection(L["Frame Display"], "visibility_framedisplay", 2, nil)
            BuildHideSelfGroup({
                group = displayBand, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(displayBand)
        end
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

        -- ★ THE FIVE "ANCHOR TO" VALUE LISTS, AT PAGE SCOPE. The Modern cards print
        -- the CHOSEN anchor as their summary, and the summary is built outside the
        -- group's builder -- so the word for FRAME has to come from the same table
        -- the dropdown offers, or a card could say "Unit Frame" while the control
        -- under it says "Buff Icon". They sit beside anchorPositionValues, which is
        -- shared by all five dropdowns for exactly this reason.
        --
        -- ⚠ FIVE TABLES, NOT THREE, even though Frame and Binding are identical
        -- today. They describe two different hovers and are free to diverge; one
        -- shared table would make a future change to either silently change both.
        -- Read-only to CreateDropdown, so sharing per-group is safe.
        local frameAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Unit Frame"],
        }
        local bindAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Unit Frame"],
        }
        local buffAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Buff Icon"],
        }
        local debuffAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Debuff Icon"],
        }
        local defAnchorValues = {
            DEFAULT = L["Game Default"],
            CURSOR = L["Cursor"],
            FRAME = L["Defensive Icon"],
        }

        -- 12.1 factory rows read all of these on the layout-version bump: the Enable
        -- toggle is structural (mouse-motion opt-in, in the row sig -> Rebuild), while
        -- anchor/offsets/combat-hide ride style.tooltip and restyle in place
        -- (SetTooltipAnchorPoint/SetHideTooltipInCombat are live mixin state, 68914+).
        --
        -- ⚠ AT PAGE SCOPE, ABOVE EVERY BUILDER. It was declared inside the Buff
        -- Tooltips block, which worked while the groups were straight-line code:
        -- the three later boxes were written after it. The builders are CLOSURES
        -- now, and a closure captures the upvalue that exists when it is created
        -- -- so a builder declared above this line would see nil rather than this
        -- function. Four groups and four footers drive it, so it has to be one
        -- reference all of them share.
        local RefreshAuraTooltips = function()
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            DF:UpdateAllFrames()
        end

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: seven 280 boxes in two columns,
        -- in the columns and the order they have always had.
        --
        -- MODERN is the Debuff Bar's collapsible-card design, one card per box:
        -- two settings per row inside a card wide enough, dim captions, the value
        -- summary in a shut card's corner, Expand All / Collapse All at the top.
        --
        --   column 1   "Unit Frame"  Frame Tooltips, Binding Tooltips -- the two
        --                            boxes that describe the SAME hover -- and
        --                            Resurrection Icon Tooltips, for balance.
        --   column 2   "Auras"       Buff, Debuff, Defensive Icon and Aura
        --                            Designer Tooltips -- hovering an ICON the
        --                            addon draws rather than the frame under it.
        --
        -- Every enable is its card's header tick (one checkbox per setting, the
        -- builder's own skipped through hoistToggle); Aura Designer Tooltips has
        -- three independent switches and no enable, and Resurrection's one
        -- checkbox IS the group. When and where a tooltip appears is behaviour,
        -- so no card is pinnable.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates } and, where the toggle moved into the
        -- header, `hoistToggle`. The classic branch mounts the SAME builder into
        -- the box it always built -- test_tooltips_page_builders.lua pins the
        -- inventory of each one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery. Its PROLOGUE closes any panel a previous
        -- build left standing and retires that build's holders, and it carries the
        -- section helper the card pages build with. nil in classic, which is what
        -- every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE SECTION: the Debuff Bar's helper (tools.OpenSection) and its two
        -- opt-ins, which every card here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ☠ WHAT AN "ANCHOR TO" CHANGE COSTS. Picking an anchor re-gates the three
        -- controls under it (the Anchor position greys under Game Default; the two
        -- offsets grey unless the tooltip is pinned to the frame or icon). A classic
        -- box and a Modern card are both page widgets, so both take the page's
        -- state pass; `popout` is only ever set by a pinned-panel mount, which has
        -- a pane of its own to reflow (no card on this page is pinnable today, so
        -- that arm is kept for the builder's shape rather than exercised).
        --
        -- ★ NEITHER LAYOUT REBUILDS. What the rebuild used to buy is the
        -- same state pass, over a page whose three controls carry their gates as
        -- disableOn -- and the rebuild leaked the whole page on every pick (see
        -- RelayoutCurrentPage in GUI/Panel.lua).
        local function AnchorGateRefresh(tools2)
            if tools2.popout then
                tools2.refreshStates()
            else
                GUI.RelayoutCurrentPage()
            end
        end

        -- ===== THE TWO SUMMARY SHAPES =====================================
        -- Both follow the sweep's convention: at most four items, a fixed order,
        -- "\194\183" between them, WORDS localised and numbers raw, every read
        -- guarded because a profile mid-migration may be missing any of these
        -- keys. Two shapes because the page has two families:
        --
        --   HOVER (Frame, Binding) -- where the tooltip attaches, then WHEN it is
        --   allowed in combat, taken straight from the five-way vocabulary those
        --   two boxes use. The out-of-combat pick is deliberately absent: it is
        --   "Always" on a default profile and on nearly every real one, so it
        --   would spend the card's width saying nothing. The in-combat pick is the
        --   one people go looking for, and it is named only when it is not the
        --   plain Always -- "Combat Never", "Combat Hold Shift".
        --
        --   AURA (Buff, Debuff, Defensive) -- the same two facts, except the
        --   combat half is a checkbox rather than a five-way pick. It reports
        --   through the SAME words: Disable in Combat on says "Combat Never",
        --   which is what it means and what the hover cards say for it.
        --
        -- ⚠ NO NEW LOCALE STRING for either. "Combat" is the word the Frame Fade
        -- card already prints beside its in-combat value, and the anchor and
        -- visibility words come out of the very tables the dropdowns offer.
        local function HoverTipSummary(anchorValues, anchorKey, combatKey)
            return function(d)
                if not d then return "" end
                local parts = {}
                local anchor = anchorValues[d[anchorKey]]
                if anchor then parts[#parts + 1] = anchor end
                local combat = d[combatKey]
                if combat and combat ~= "SHOW" and VIS_VALUES[combat] then
                    parts[#parts + 1] = format("%s %s", L["Combat"], VIS_VALUES[combat])
                end
                return table.concat(parts, " \194\183 ")
            end
        end

        local function AuraTipSummary(anchorValues, anchorKey, combatKey)
            return function(d)
                if not d then return "" end
                local parts = {}
                local anchor = anchorValues[d[anchorKey]]
                if anchor then parts[#parts + 1] = anchor end
                if d[combatKey] then
                    parts[#parts + 1] = format("%s %s", L["Combat"], L["Never"])
                end
                return table.concat(parts, " \194\183 ")
            end
        end

        -- ===== Frame Tooltips + Buff Tooltips (classic row 1) =====

        -- Frame Tooltips (a 280 box in column 1 in classic, the first Unit Frame
        -- card in Modern). Verbatim, taking the group and parent it should build
        -- into: same factories, same L keys, same db keys, same slot heights, same
        -- disableOn.
        --
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER. In classic the box greys its
        -- own children while frame tooltips are off; the card's body has to do the
        -- same while its header tick is off, and one builder serving both is what
        -- stops the two drifting.
        local function BuildFrameTooltipGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the card's HEADER carries this tick. Still built in classic,
            -- where it is the group's only on/off control.
            if not tools2.hoistToggle then
                local frameTooltipEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Frame Tooltips"], db, "tooltipFrameEnabled", nil), 30)
                frameTooltipEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.tooltipFrameEnabled end

            local frameVisOOC = group:AddWidget(GUI:CreateDropdown(parent, L["Show Out of Combat"],
                VIS_VALUES, db, "tooltipFrameOutOfCombat", function() end), 55)
            frameVisOOC.tooltip = TIP_VIS_OOC

            local frameVisCombat = group:AddWidget(GUI:CreateDropdown(parent, L["Show In Combat"],
                VIS_VALUES, db, "tooltipFrameCombat", function() end), 55)
            frameVisCombat.tooltip = TIP_VIS_COMBAT

            local frameAnchorTo = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor To"], frameAnchorValues, db, "tooltipFrameAnchor", function() AnchorGateRefresh(tools2) end), 55)
            frameAnchorTo.tooltip = TIP_ANCHOR_TO

            local frameAnchorPos = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorPositionValues, db, "tooltipFrameAnchorPos", function() end), 55)
            frameAnchorPos.disableOn = function(d) return d.tooltipFrameAnchor == "DEFAULT" end
            frameAnchorPos.tooltip = TIP_ANCHOR_POS

            local frameOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -100, 100, 1, db, "tooltipFrameX", function() end), 55)
            frameOffsetX.disableOn = function(d) return d.tooltipFrameAnchor ~= "FRAME" end

            local frameOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -100, 100, 1, db, "tooltipFrameY", function() end), 55)
            frameOffsetY.disableOn = function(d) return d.tooltipFrameAnchor ~= "FRAME" end
        end

        if classicLayout then
            local frameTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
            frameTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Tooltips"]), 40)
            BuildFrameTooltipGroup({
                group = frameTooltipGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(frameTooltipGroup, nil, 1)
        else
            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Buff Bar's placement and its reasons: they act on cards in both
            -- columns, and "both" carries them through the one-column fold intact.
            Add(tools.SectionControls(self.child), 24, "both")
            -- The category header the three Unit Frame cards sit under -- the very
            -- word the first two cards' Anchor To dropdowns use for the thing
            -- they attach to.
            Add(GUI:CreateHeader(self.child, L["Unit Frame"]), 40, 1)
            -- ☠ THE ENABLE IS THE HEADER'S TICK, so the builder is told not to
            -- build its own (hoistToggle). Every control here is read at HOVER
            -- time, so the commit is only the state pass that greys the body --
            -- never a page rebuild. When a tooltip appears is behaviour, not
            -- looks, so no pin.
            local band = OpenSection(L["Frame Tooltips"], "tooltips_frame", 1,
                HoverTipSummary(frameAnchorValues, "tooltipFrameAnchor", "tooltipFrameCombat"),
                nil, nil, nil, {
                    db = db, key = "tooltipFrameEnabled", label = L["Enable Frame Tooltips"],
                    onChanged = function() self:RefreshStates() end,
                })
            BuildFrameTooltipGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- Binding Tooltips (a 280 box in column 2 in classic, the second Unit
        -- Frame card in Modern) — pairs with Frame Tooltips: both anchor to the
        -- Unit Frame, so they are the two boxes describing the SAME hover. In
        -- classic they sat side by side and the reader had to notice; in Modern
        -- the "Unit Frame" header over both says it.
        local function BuildBindTooltipGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            if not tools2.hoistToggle then
                local bindTooltipEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Binding Tooltips"], db, "tooltipBindingEnabled", nil), 30)
                bindTooltipEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.tooltipBindingEnabled end

            local bindVisOOC = group:AddWidget(GUI:CreateDropdown(parent, L["Show Out of Combat"],
                VIS_VALUES, db, "tooltipBindingOutOfCombat", function() end), 55)
            bindVisOOC.tooltip = TIP_VIS_OOC

            local bindVisCombat = group:AddWidget(GUI:CreateDropdown(parent, L["Show In Combat"],
                VIS_VALUES, db, "tooltipBindingCombat", function() end), 55)
            bindVisCombat.tooltip = TIP_VIS_COMBAT

            local bindAnchorTo = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor To"], bindAnchorValues, db, "tooltipBindingAnchor", function() AnchorGateRefresh(tools2) end), 55)
            bindAnchorTo.tooltip = TIP_ANCHOR_TO

            local bindAnchorPos = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorPositionValues, db, "tooltipBindingAnchorPos", function() end), 55)
            bindAnchorPos.disableOn = function(d) return d.tooltipBindingAnchor == "DEFAULT" end
            bindAnchorPos.tooltip = TIP_ANCHOR_POS

            local bindOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -100, 100, 1, db, "tooltipBindingX", function() end), 55)
            bindOffsetX.disableOn = function(d) return d.tooltipBindingAnchor ~= "FRAME" end

            local bindOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -100, 100, 1, db, "tooltipBindingY", function() end), 55)
            bindOffsetY.disableOn = function(d) return d.tooltipBindingAnchor ~= "FRAME" end
        end

        if classicLayout then
            local bindTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
            bindTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Binding Tooltips"]), 40)
            BuildBindTooltipGroup({
                group = bindTooltipGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(bindTooltipGroup, nil, 2)
        else
            -- The Frame Tooltips card's shape and reasoning: the same gated chain
            -- of picks over the same hover, the enable in the header.
            local band = OpenSection(L["Binding Tooltips"], "tooltips_binding", 1,
                HoverTipSummary(bindAnchorValues, "tooltipBindingAnchor", "tooltipBindingCombat"),
                nil, nil, nil, {
                    db = db, key = "tooltipBindingEnabled", label = L["Enable Binding Tooltips"],
                    onChanged = function() self:RefreshStates() end,
                })
            BuildBindTooltipGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- Buff Tooltips (a 280 box in column 1 in classic, the first Auras card
        -- in Modern).
        local function BuildBuffTooltipGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            if not tools2.hoistToggle then
                local buffTooltipEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Buff Tooltips"], db, "tooltipBuffEnabled", RefreshAuraTooltips), 30)
                buffTooltipEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.tooltipBuffEnabled end
            group:AddWidget(GUI:CreateCheckbox(parent, L["Disable in Combat"], db, "tooltipBuffDisableInCombat", RefreshAuraTooltips), 30)

            local buffAnchorTo = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor To"], buffAnchorValues, db, "tooltipBuffAnchor", function() RefreshAuraTooltips() AnchorGateRefresh(tools2) end), 55)
            buffAnchorTo.tooltip = TIP_ANCHOR_TO

            local buffAnchorPos = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorPositionValues, db, "tooltipBuffAnchorPos", RefreshAuraTooltips), 55)
            buffAnchorPos.disableOn = function(d) return d.tooltipBuffAnchor == "DEFAULT" end
            buffAnchorPos.tooltip = TIP_ANCHOR_POS

            local buffOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, db, "tooltipBuffX", RefreshAuraTooltips), 55)
            buffOffsetX.disableOn = function(d) return d.tooltipBuffAnchor ~= "FRAME" end

            local buffOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, db, "tooltipBuffY", RefreshAuraTooltips), 55)
            buffOffsetY.disableOn = function(d) return d.tooltipBuffAnchor ~= "FRAME" end
        end

        if classicLayout then
            local buffTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
            buffTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Buff Tooltips"]), 40)
            BuildBuffTooltipGroup({
                group = buffTooltipGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(buffTooltipGroup, nil, 1)
        else
            -- Column 2 opens here, with the category header the four aura cards
            -- sit under.
            Add(GUI:CreateHeader(self.child, L["Auras"]), 40, 2)
            -- ☠ THE ENABLE IS THE HEADER'S TICK, so the builder is told not to
            -- build its own (hoistToggle). The commit is what the in-body
            -- checkbox ran (the aura buttons are the game's own, so a changed flag
            -- has to be pushed into them) plus the state pass that greys the
            -- body -- never a page rebuild. When a tooltip appears is behaviour,
            -- not looks, so no pin.
            local band = OpenSection(L["Buff Tooltips"], "tooltips_buff", 2,
                AuraTipSummary(buffAnchorValues, "tooltipBuffAnchor", "tooltipBuffDisableInCombat"),
                nil, nil, nil, {
                    db = db, key = "tooltipBuffEnabled", label = L["Enable Buff Tooltips"],
                    onChanged = function()
                        RefreshAuraTooltips()
                        self:RefreshStates()
                    end,
                })
            BuildBuffTooltipGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

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
        --
        -- ⚠ ALL OF THAT IS ABOUT THE CLASSIC LAYOUT ONLY, and it still holds
        -- there. Modern's cards are column-filling and two per row inside, so
        -- none of these heights apply; its columns are split by subject instead
        -- (Unit Frame left, Auras right).

        -- Debuff Tooltips (a 280 box in column 2 in classic, the second Auras
        -- card in Modern).
        local function BuildDebuffTooltipGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            if not tools2.hoistToggle then
                local debuffTooltipEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Debuff Tooltips"], db, "tooltipDebuffEnabled", RefreshAuraTooltips), 30)
                debuffTooltipEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.tooltipDebuffEnabled end
            group:AddWidget(GUI:CreateCheckbox(parent, L["Disable in Combat"], db, "tooltipDebuffDisableInCombat", RefreshAuraTooltips), 30)

            local debuffAnchorTo = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor To"], debuffAnchorValues, db, "tooltipDebuffAnchor", function() RefreshAuraTooltips() AnchorGateRefresh(tools2) end), 55)
            debuffAnchorTo.tooltip = TIP_ANCHOR_TO

            local debuffAnchorPos = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorPositionValues, db, "tooltipDebuffAnchorPos", RefreshAuraTooltips), 55)
            debuffAnchorPos.disableOn = function(d) return d.tooltipDebuffAnchor == "DEFAULT" end
            debuffAnchorPos.tooltip = TIP_ANCHOR_POS

            local debuffOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, db, "tooltipDebuffX", RefreshAuraTooltips), 55)
            debuffOffsetX.disableOn = function(d) return d.tooltipDebuffAnchor ~= "FRAME" end

            local debuffOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, db, "tooltipDebuffY", RefreshAuraTooltips), 55)
            debuffOffsetY.disableOn = function(d) return d.tooltipDebuffAnchor ~= "FRAME" end
        end

        if classicLayout then
            local debuffTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
            debuffTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Debuff Tooltips"]), 40)
            BuildDebuffTooltipGroup({
                group = debuffTooltipGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(debuffTooltipGroup, nil, 2)
        else
            -- The Buff Tooltips card's shape: one group, two auras.
            local band = OpenSection(L["Debuff Tooltips"], "tooltips_debuff", 2,
                AuraTipSummary(debuffAnchorValues, "tooltipDebuffAnchor", "tooltipDebuffDisableInCombat"),
                nil, nil, nil, {
                    db = db, key = "tooltipDebuffEnabled", label = L["Enable Debuff Tooltips"],
                    onChanged = function()
                        RefreshAuraTooltips()
                        self:RefreshStates()
                    end,
                })
            BuildDebuffTooltipGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- Defensive Icon Tooltips (a 280 box in column 1 in classic, the third
        -- Auras card in Modern).
        local function BuildDefTooltipGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            if not tools2.hoistToggle then
                local defTooltipEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Defensive Icon Tooltips"], db, "tooltipDefensiveEnabled", RefreshAuraTooltips), 30)
                defTooltipEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.tooltipDefensiveEnabled end
            group:AddWidget(GUI:CreateCheckbox(parent, L["Disable in Combat"], db, "tooltipDefensiveDisableInCombat", RefreshAuraTooltips), 30)

            local defAnchorTo = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor To"], defAnchorValues, db, "tooltipDefensiveAnchor", function() RefreshAuraTooltips() AnchorGateRefresh(tools2) end), 55)
            defAnchorTo.tooltip = TIP_ANCHOR_TO

            local defAnchorPos = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorPositionValues, db, "tooltipDefensiveAnchorPos", RefreshAuraTooltips), 55)
            defAnchorPos.disableOn = function(d) return d.tooltipDefensiveAnchor == "DEFAULT" end
            defAnchorPos.tooltip = TIP_ANCHOR_POS

            local defOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -100, 100, 1, db, "tooltipDefensiveX", RefreshAuraTooltips), 55)
            defOffsetX.disableOn = function(d) return d.tooltipDefensiveAnchor ~= "FRAME" end

            local defOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -100, 100, 1, db, "tooltipDefensiveY", RefreshAuraTooltips), 55)
            defOffsetY.disableOn = function(d) return d.tooltipDefensiveAnchor ~= "FRAME" end
        end

        if classicLayout then
            local defTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
            defTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Defensive Icon Tooltips"]), 40)
            BuildDefTooltipGroup({
                group = defTooltipGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(defTooltipGroup, nil, 1)
        else
            -- The third of the aura trio, and the Buff Tooltips card's shape:
            -- the enable is the header's tick (the builder skips its own).
            local band = OpenSection(L["Defensive Icon Tooltips"], "tooltips_defensive", 2,
                AuraTipSummary(defAnchorValues, "tooltipDefensiveAnchor", "tooltipDefensiveDisableInCombat"),
                nil, nil, nil, {
                    db = db, key = "tooltipDefensiveEnabled", label = L["Enable Defensive Icon Tooltips"],
                    onChanged = function()
                        RefreshAuraTooltips()
                        self:RefreshStates()
                    end,
                })
            BuildDefTooltipGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- Aura Designer Tooltips (a 280 box in column 2 in classic, the last
        -- Auras card in Modern). Lives HERE rather than on the Aura
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
        --
        -- ☠ A CARD WITH NO HEADER TICK, and that is a judgement rather than an
        -- omission. The other four aura groups each have one boolean meaning "am
        -- I doing anything at all"; this one has THREE, and they are INDEPENDENT
        -- -- any of the three surfaces can have a tooltip without the others.
        -- Hoisting one would claim it speaks for all three, and inventing a
        -- fourth key to gate them is a migration for a header's ornament. So the
        -- three stay in the body and the group reads as permanently on, which it
        -- is.
        local function BuildADTooltipGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local adGroupsTip = group:AddWidget(GUI:CreateCheckbox(parent, L["Groups"], db, "tooltipADGroupsEnabled", RefreshAuraTooltips), 30)
            adGroupsTip.tooltip = L["Filter Groups and Debuff Groups. Their icons come from a filter rather than being placed one by one, so a tooltip is the only way to see what each one is."]
            local adIndTip = group:AddWidget(GUI:CreateCheckbox(parent, L["Indicators"], db, "tooltipADIndicatorsEnabled", RefreshAuraTooltips), 30)
            adIndTip.tooltip = L["Icons and squares you placed yourself. You already chose these, so tooltips add less here."]
            local adBarTip = group:AddWidget(GUI:CreateCheckbox(parent, L["Bars"], db, "tooltipADBarsEnabled", RefreshAuraTooltips), 30)
            adBarTip.tooltip = L["The Aura Designer bar."]
        end

        if classicLayout then
            local adTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
            adTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Aura Designer Tooltips"]), 40)
            BuildADTooltipGroup({
                group = adTooltipGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(adTooltipGroup, nil, 2)
        else
            -- Which of the three surfaces are on, in the order the checkboxes
            -- are in. Three items at most, all of them single words the locale
            -- already ships as those checkboxes' own labels -- and with none of
            -- them on it says nothing, which is the honest answer for a card
            -- whose whole group is off.
            local function ADTooltipSummary(d)
                if not d then return "" end
                local parts = {}
                if d.tooltipADGroupsEnabled then parts[#parts + 1] = L["Groups"] end
                if d.tooltipADIndicatorsEnabled then parts[#parts + 1] = L["Indicators"] end
                if d.tooltipADBarsEnabled then parts[#parts + 1] = L["Bars"] end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ NO HEADER TICK: three INDEPENDENT switches and no one of them is
            -- the group's on/off (see the builder's note). Behaviour, so no pin.
            local band = OpenSection(L["Aura Designer Tooltips"], "tooltips_auradesigner", 2, ADTooltipSummary)
            BuildADTooltipGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- Resurrection Icon Tooltips (Column 2 in classic; the last Unit Frame
        -- card in Modern) — the one short box, kept last so the leftover space
        -- lands at the foot of a column.
        --
        -- ☠ ONE SETTING, SO ITS CARD HOLDS THE CHECKBOX AND NO HEADER TICK. The
        -- enable is the whole group: hoisted, it would leave a card with an empty
        -- body under a tick. The same call classic makes, on the same key, so the
        -- search entry is the one classic registers. Its column is the Unit Frame
        -- side for balance (three cards against four), as the old row's was.
        if classicLayout then
            local resTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
            resTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Resurrection Icon Tooltips"]), 40)
            resTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Resurrection Icon Tooltips"], db, "tooltipResurrectionEnabled", nil), 30)
            Add(resTooltipGroup, nil, 2)
        else
            local band = OpenSection(L["Resurrection Icon Tooltips"], "tooltips_resurrection", 1, nil)
            band:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Resurrection Icon Tooltips"], db, "tooltipResurrectionEnabled", nil), 30)
            CloseSection(band)
        end

        -- ===== NO BAND TAIL ================================================
        -- A card's band holds one group and is Add'd by CloseSection the moment
        -- that group is built, so nothing is deferred to here. Unit Frame down the
        -- left, Auras down the right; on a narrow window the page folds to one
        -- column in the order above.

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
    -- ★ PER-BUILD PAGE FIELDS. The range-spell helpers reach the input and its
    -- label through these page fields, so with a party AND a raid build retained
    -- (see ONE RETAINED BUILD PER MODE in GUI/Panel.lua) each build must bring its
    -- own pair back when it is swapped in.
    if pageFading then pageFading.modeBuildFields = { "rangeSpellInput", "rangeSpellInfoLabel" } end
    BuildPage(pageFading, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right.
        -- ☠ These prefixes are matched CASE-SENSITIVELY from the START of the key
        -- (DF:SectionOwnsKey), and the SAME list drives Copy, Sync AND Reset Page.
        -- "dead" and "offline" matched nothing: the keys are fadeDead*, which begins
        -- "fade". So the entire Dead/Offline Fading box was silently dropped from all
        -- three. Prefixes must be real key prefixes, not the box's name.
        Add(CreateCopyButton(self.child, {"rangeFade", "rangeCheck", "rangeUpdate", "oor", "fadeDead", "healthFade", "hf"}, L["Fading"], "display_fading"), 25, 2)

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: three 280 boxes -- Out of Range in
        -- column 1, then Dead/Offline Fading and Health Threshold Fading stacked in
        -- column 2 with the block spacer between them.
        --
        -- MODERN is the Debuff Bar's collapsible-card design: two settings per row
        -- inside a card wide enough, dim captions, the value summary in a shut
        -- card's corner, Expand All / Collapse All at the top. FOUR cards, because
        -- the Out of Range box is split in two (see its builder):
        --
        --   column 1   Out of Range (no on/off), Element-Specific Alpha (tick:
        --              oorEnabled)
        --   column 2   Dead/Offline Fading (tick: fadeDeadFrames), Health
        --              Threshold Fading (tick: healthFadeEnabled)
        --
        -- Every feature that has an enable carries it as its header tick (one
        -- checkbox per setting, the builder's own skipped through hoistToggle).
        -- The three fades are how a frame LOOKS, so they are pinnable; the range
        -- check is behaviour and is not.
        --
        -- ⚠ NO CATEGORY HEADERS. A header names a SECTION -- and the section here
        -- is the whole page, which the tab already calls "Fading".
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates } and, where the toggle moved into the
        -- header, `hoistToggle`. The classic branch mounts the SAME builders into
        -- the boxes it always built -- test_fading_page_builders.lua pins the
        -- inventory of each one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery. Its PROLOGUE closes any panel a previous
        -- build left standing and retires that build's holders, and it carries the
        -- section helper the card pages build with. nil in classic, which is what
        -- every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE SECTION: the Debuff Bar's helper (tools.OpenSection) and its two
        -- opt-ins, which every card here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

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

        -- ☠ THREE HELPERS MOVED UP TO PAGE SCOPE, ABOVE EVERY BUILDER. All three
        -- used to sit in the straight-line code between the controls that call
        -- them, which was fine while the page WAS straight-line code. The builders
        -- are CLOSURES now, and a closure captures the upvalue that exists when it
        -- is CREATED -- so a builder declared above one of these would see nil
        -- rather than the function.
        --
        -- ⚠ THE RANGE PAIR READS THE PAGE'S OWN FIELDS (self.rangeSpellInput,
        -- self.rangeSpellInfoLabel) rather than locals, and that indirection is
        -- what makes them work in BOTH layouts: the builder stamps them wherever
        -- it is mounted, the classic box or the Out of Range card. (Which is why
        -- that card grows no pin: a second, pinned copy would re-point them.)
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

        -- Health fade sliders need UpdateAllFrameAppearances to force an immediate visual refresh.
        -- Unlike OOR/dead fade which refresh on range/state changes, health fade alpha values
        -- are only re-read during appearance updates, not triggered by FullFrameRefresh alone.
        local function RefreshHealthFade()
            if DF.InvalidateHealthFadeCurve then DF:InvalidateHealthFadeCurve() end
            DF:RefreshAllVisibleFrames()
            if DF.UpdateAllFrameAppearances then DF:UpdateAllFrameAppearances() end
        end

        -- ===== OUT OF RANGE (a 280 box in column 1 in classic, TWO cards in
        -- Modern) =====
        -- Verbatim, taking the group and parent it should build into: same
        -- factories, same L keys, same db keys, same callbacks, same slot heights,
        -- same hideOn/disableOn -- split into the two builders below, which the
        -- classic box mounts back to back (BuildOutOfRangeGroup) and Modern mounts
        -- as two cards.
        --
        -- ☠ WHY TWO. The range check (spell, custom spell, interval, frame-level
        -- alpha) has no on/off: out of range fades either way. The twelve
        -- per-element alphas DO -- oorEnabled -- and as one card that switch could
        -- not go in the header without claiming to speak for the range spell too,
        -- and it HIDES the frame-level slider, so a tick over the whole group
        -- would grey the one control the group is left with. Split, the second
        -- card's header carries it honestly, the way the two fades beside it do.
        --
        -- ☠ THE TWO db SEEDS STAY EXACTLY WHERE THEY WERE, inside the builder and
        -- ahead of the control that reads them. They are the page's only build-time
        -- writes, so they still land at the moment they always did -- which is
        -- what the export byte-identity gate measures.
        local function BuildRangeCheckGroup(tools2)
            local group, parent = tools2.group, tools2.parent

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

            -- Range Check Spell row
            local rangeSpellDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Range Check Spell"], GetRangeSpellDropdownOptions(), db, "rangeCheckSpellID", SetRangeSpellValue), 55)
            rangeSpellDropdown.tooltip = L["Select which spell to use for range checking. Auto will use your spec's default healing/friendly spell."]

            -- Custom Spell ID Input
            local customSpellInput = group:AddWidget(GUI:CreateInput(parent, L["Custom Spell ID"], 120), 55)
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
            local infoLabel = group:AddWidget(GUI:CreateLabel(parent, "|cFFAAAAAA" .. L["Active:"] .. " " .. rangeInfoText .. "|r", 250), 25)
            self.rangeSpellInfoLabel = infoLabel

            -- Range update interval
            if db.rangeUpdateInterval == nil then
                db.rangeUpdateInterval = 0.5
            end
            local intervalSlider = group:AddWidget(GUI:CreateSlider(parent, L["Range Check Interval"], 0.1, 1.0, 0.05, db, "rangeUpdateInterval", nil, function()
                if DF.SetRangeUpdateInterval then
                    DF:SetRangeUpdateInterval(db.rangeUpdateInterval)
                end
            end, true), 55)
            intervalSlider.tooltip = L["How often to check range (seconds). Lower = more responsive but higher CPU. Default: 0.5s"]

            -- Frame-level alpha (shown when element-specific is disabled)
            local frameLevelAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Frame Alpha (Out of Range)"], 0.1, 1.0, 0.05, db, "rangeFadeAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            frameLevelAlpha.hideOn = HideFrameLevelAlpha
        end

        -- ===== ELEMENT-SPECIFIC ALPHA (the second half of the classic Out of
        -- Range box, a card of its own in Modern) =====
        -- The switch and the twelve per-element alphas behind it. Verbatim, less
        -- the switch when the card's HEADER carries it.
        local function BuildElementAlphaGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Element-specific toggle.
            -- ⚠ tools2.refreshStates, NOT self:RefreshStates. This tick drives a
            -- hideOn on the frame-level slider, so a pinned panel holding it
            -- changes HEIGHT when it is clicked and has to be told; the page's own
            -- refresh alone never reaches a group living in a popout holder. On
            -- the page the tools2 hook IS self:RefreshStates.
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Element-Specific Alpha"], db, "oorEnabled", function()
                    tools2.refreshStates()
                end), 30)
            end

            -- Element-specific sliders (shown when enabled)
            local oorHealth = group:AddWidget(GUI:CreateSlider(parent, L["Health Bar Alpha"], 0.0, 1.0, 0.05, db, "oorHealthBarAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorHealth.disableOn = HideOOROptions

            local oorMissingHealth = group:AddWidget(GUI:CreateSlider(parent, L["Missing Health Alpha"], 0.0, 1.0, 0.05, db, "oorMissingHealthAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorMissingHealth.disableOn = HideOOROptions

            local oorBg = group:AddWidget(GUI:CreateSlider(parent, L["Background Alpha"], 0.0, 1.0, 0.05, db, "oorBackgroundAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorBg.disableOn = HideOOROptions

            local oorBorder = group:AddWidget(GUI:CreateSlider(parent, L["Border Alpha"], 0.0, 1.0, 0.05, db, "oorBorderAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorBorder.disableOn = HideOOROptions

            -- Unified Text Alpha: the Text Designer now renders all unit text, so a
            -- single OOR alpha dims every TD text element (name/health/power/custom)
            -- out of range — replacing the old per-element Name/Health text alphas.
            local oorText = group:AddWidget(GUI:CreateSlider(parent, L["Text Alpha"], 0.0, 1.0, 0.05, db, "oorTextAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorText.disableOn = HideOOROptions

            local oorAuras = group:AddWidget(GUI:CreateSlider(parent, L["Auras Alpha"], 0.0, 1.0, 0.05, db, "oorAurasAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorAuras.disableOn = HideOOROptions

            local oorIcons = group:AddWidget(GUI:CreateSlider(parent, L["Icons Alpha"], 0.0, 1.0, 0.05, db, "oorIconsAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorIcons.disableOn = HideOOROptions

            local oorDispel = group:AddWidget(GUI:CreateSlider(parent, L["Dispel Overlay Alpha"], 0.0, 1.0, 0.05, db, "oorDispelOverlayAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorDispel.disableOn = HideOOROptions

            local oorPower = group:AddWidget(GUI:CreateSlider(parent, L["Power Bar Alpha"], 0.0, 1.0, 0.05, db, "oorPowerBarAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorPower.disableOn = HideOOROptions

            local oorMissingBuff = group:AddWidget(GUI:CreateSlider(parent, L["Missing Buff Alpha"], 0.0, 1.0, 0.05, db, "oorMissingBuffAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorMissingBuff.disableOn = HideOOROptions

            local oorDefensive = group:AddWidget(GUI:CreateSlider(parent, L["Defensive Icon Alpha"], 0.0, 1.0, 0.05, db, "oorDefensiveIconAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorDefensive.disableOn = HideOOROptions

            local oorAuraDesigner = group:AddWidget(GUI:CreateSlider(parent, L["Aura Designer Alpha"], 0.0, 1.0, 0.05, db, "oorAuraDesignerAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            oorAuraDesigner.disableOn = HideOOROptions
        end

        -- The classic box's builder: both halves, back to back, into the ONE box,
        -- in the order the seventeen controls always had.
        local function BuildOutOfRangeGroup(tools2)
            BuildRangeCheckGroup(tools2)
            BuildElementAlphaGroup(tools2)
        end

        if classicLayout then
            -- ===== OUT OF RANGE GROUP (Column 1) =====
            local oorGroup = GUI:CreateSettingsGroup(self.child, 280)
            oorGroup:AddWidget(GUI:CreateHeader(self.child, L["Out of Range"]), 40)
            BuildOutOfRangeGroup({
                group = oorGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(oorGroup, nil, 1)
        else
            -- The two summaries, per the sweep's convention: at most four items, a
            -- fixed order, "\194\183" between them, WORDS localised and numbers
            -- raw, every read guarded because a profile mid-migration may be
            -- missing any of these keys.
            --
            -- Out of Range reports the ONE frame-level alpha, and only while it
            -- is the one in use: with element-specific alpha on, the frame-level
            -- slider is hidden and a number labelled "Alpha" would be a lie. The
            -- range SPELL is deliberately absent -- it is a spell name rather than
            -- a setting value, and the card's own info label says which is live.
            local function OutOfRangeSummary(d)
                if not d then return "" end
                if d.oorEnabled then return "" end
                local a = tonumber(d.rangeFadeAlpha)
                if not a then return "" end
                return format("%s %.2f", L["Alpha"], a)
            end
            -- Element-Specific Alpha names the HEALTH BAR's alpha -- the element
            -- that covers most of the frame and the one people mean by "how
            -- faded is it". A shut card reads "Off" while its tick is off.
            local function ElementAlphaSummary(d)
                if not d then return "" end
                local hp = tonumber(d.oorHealthBarAlpha)
                if not hp then return "" end
                return format("%s %.2f", L["Health Bar Alpha"], hp)
            end

            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Buff Bar's placement and its reasons: they act on cards in both
            -- columns, and "both" carries them through the one-column fold intact.
            Add(tools.SectionControls(self.child), 24, "both")

            -- ☠ NO TICK, AND NO PIN. Out of range fading has no on/off: it fades
            -- either way, through the one frame-level alpha or the per-element
            -- ones below. The range spell and the check interval are behaviour,
            -- and the builder stamps self.rangeSpellInput / rangeSpellInfoLabel
            -- for the range helpers -- a pinned second copy would re-point them.
            local rangeBand = OpenSection(L["Out of Range"], "fading_range", 1, OutOfRangeSummary)
            BuildRangeCheckGroup({
                group = rangeBand, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(rangeBand)

            -- ☠ THE CLASSIC BOX'S SECOND HALF, AS ITS OWN CARD. Twelve per-element
            -- alphas behind one switch is a feature with an on/off, so the switch
            -- is the header's tick (hoistToggle) -- the consistency the other two
            -- fades on this page already have. The commit is the state pass the
            -- in-body checkbox ran: it greys the twelve here and swaps the
            -- frame-level slider in the card above in or out. How faded each
            -- element is is how it LOOKS, so it is pinnable.
            local elementBand = OpenSection(L["Element-Specific Alpha"], "fading_elements", 1, ElementAlphaSummary, nil, nil,
                BuildElementAlphaGroup, {
                    db = db, key = "oorEnabled", label = L["Enable Element-Specific Alpha"],
                    onChanged = function()
                        self:RefreshStates()
                        tools.ReflowMounted()
                    end,
                })
            BuildElementAlphaGroup({
                group = elementBand, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(elementBand)
        end

        -- ===== DEAD/OFFLINE FADING (a 280 box in column 2 in classic, the first
        -- column-2 card in Modern) =====
        -- The textbook header tick: one enable with keepEnabled and a group gate
        -- that greys everything behind it, which is the shape of "am I doing
        -- anything at all".
        --
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER. In classic the box greys its
        -- own children while dead fading is off; the card's body has to do the
        -- same while its header tick is off, and one builder serving both is what
        -- stops the two drifting.
        local function BuildDeadFadeGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the card's HEADER carries this tick. Still built in classic,
            -- where it is the group's only on/off control.
            if not tools2.hoistToggle then
                local deadFadeEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Dead Fade"], db, "fadeDeadFrames", function()
                    tools2.refreshStates()
                    DF:UpdateAllFrames()
                    DF:RefreshAllVisibleFrames()
                end), 30)
                deadFadeEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.fadeDeadFrames end

            -- Sliders grey out (disabled-in-place) via group.disableChildrenOn above.
            group:AddWidget(GUI:CreateSlider(parent, L["Background Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadBackground", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Health Bar Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadHealthBar", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Name Text Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadName", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Power Bar Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadPowerBar", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Icons Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadIcons", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Auras Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadAuras", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Status Text Alpha"], 0.0, 1.0, 0.05, db, "fadeDeadStatusText", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)

            -- ⚠ tools2.refreshStates, NOT self:RefreshStates: this tick gates the
            -- colour picker under it, and a group living in a popout holder is not
            -- reached by the page's own state pass. Identical in classic, where the
            -- tools2 hook IS self:RefreshStates.
            group:AddWidget(GUI:CreateCheckbox(parent, L["Custom Dead Background"], db, "fadeDeadUseCustomColor", function()
                tools2.refreshStates()
                DF:UpdateAllFrames()
                DF:RefreshAllVisibleFrames()
            end), 30)

            -- Colour picker also greys on the useCustomColor variant (disableOn composes
            -- with the group's enable gate).
            local deadBgColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Dead Background Color"], db, "fadeDeadBackgroundColor", false, function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 35)
            deadBgColor.disableOn = function(d) return not d.fadeDeadUseCustomColor end
        end

        if classicLayout then
            -- ===== DEAD/OFFLINE FADING GROUP (Column 2) =====
            local deadGroup = GUI:CreateSettingsGroup(self.child, 280)
            deadGroup:AddWidget(GUI:CreateHeader(self.child, L["Dead/Offline Fading"]), 40)
            BuildDeadFadeGroup({
                group = deadGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(deadGroup, nil, 2)
        else
            -- The header tick already says whether dead fading is on (a shut card
            -- reads "Off" while it is not), so the summary is about what is BEHIND
            -- it -- and only where that is doing something. Seven alphas cannot
            -- fit, so it names the one that covers most of the frame, and only
            -- when it actually fades; the custom background follows it, in that
            -- checkbox's own words.
            local function DeadFadeSummary(d)
                if not d then return "" end
                local parts = {}
                local hp = tonumber(d.fadeDeadHealthBar)
                if hp and hp < 1 then parts[#parts + 1] = format("%s %.2f", L["Health Bar Alpha"], hp) end
                if d.fadeDeadUseCustomColor then parts[#parts + 1] = L["Custom Dead Background"] end
                return table.concat(parts, " \194\183 ")
            end

            -- Column 2 opens here.
            -- ☠ THE ENABLE IS THE HEADER'S TICK, so the builder is told not to
            -- build its own (hoistToggle). The commit is what the in-body checkbox
            -- ran (its tools2.refreshStates is the state pass here) -- never a
            -- page rebuild. How a dead frame is drawn is how it LOOKS, so it is
            -- pinnable.
            local band = OpenSection(L["Dead/Offline Fading"], "fading_dead", 2, DeadFadeSummary, nil, nil,
                BuildDeadFadeGroup, {
                    db = db, key = "fadeDeadFrames", label = L["Enable Dead Fade"],
                    onChanged = function()
                        self:RefreshStates()
                        DF:UpdateAllFrames()
                        DF:RefreshAllVisibleFrames()
                        tools.ReflowMounted()
                    end,
                })
            BuildDeadFadeGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- ===== HEALTH THRESHOLD FADING (a 280 box in column 2 in classic, the
        -- second column-2 card in Modern) =====
        -- The same textbook hoist as Dead/Offline: keepEnabled plus a group gate.
        local function BuildHealthFadeGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            if not tools2.hoistToggle then
                local hfEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Health Threshold Fade"], db, "healthFadeEnabled", function()
                    tools2.refreshStates()
                    DF:UpdateAllFrames()
                    DF:RefreshAllVisibleFrames()
                end), 30)
                hfEnable.keepEnabled = true
                -- A SettingsGroup has no tooltip support, so this belongs on the enable
                -- toggle -- the control you hover to ask "what is this?".
                hfEnable.tooltip = L["Fade frames or elements when a unit's health is above the set threshold (e.g. 100% or 80%)."]
            end
            group.disableChildrenOn = function(d) return not d.healthFadeEnabled end

            local hfThreshold = group:AddWidget(GUI:CreateSlider(parent, L["Health Threshold (%)"], 50, 100, 1, db, "healthFadeThreshold", function()
                DF:UpdateAllFrames()
                DF:RefreshAllVisibleFrames()
            end), 55)
            hfThreshold.tooltip = L["Units at or above this health percent are faded."]

            group:AddWidget(GUI:CreateCheckbox(parent, L["Cancel Fade on Dispellable Debuff"], db, "hfCancelOnDispel", function()
                DF:UpdateAllFrames()
                DF:RefreshAllVisibleFrames()
            end), 30)

            local hfFrameAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Frame Alpha (Above Threshold)"], 0.1, 1.0, 0.05, db, "healthFadeAlpha", nil, RefreshHealthFade, true), 55)
            hfFrameAlpha.tooltip = L["Frame opacity when health is above the threshold."]
        end

        if classicLayout then
            -- ===== HEALTH THRESHOLD FADING (col2) =====
            -- Column width, and the spacer above it is column 2 as well. A "both"
            -- widget takes the LOWER of the two columns and drops both to it, so a
            -- "both" spacer here would push column 2 down past the bottom of the
            -- out-of-range group in column 1 and leave a hole under Dead/Offline.
            --
            -- Column 2 rather than 1 because column 1 carries the out-of-range group
            -- and its long stack of per-element sliders, far and away the tallest
            -- thing on the page.
            --
            -- ⚠ ALL OF THAT IS ABOUT THE CLASSIC LAYOUT ONLY, which is why the
            -- spacer lives in this arm: the popout layout has no columns left to
            -- balance -- all three groups are rows in one full-width band.
            AddSpace(GUI.Space.block, 2)
            local hfGroup = GUI:CreateSettingsGroup(self.child, 280)
            hfGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Threshold Fading"]), 40)
            BuildHealthFadeGroup({
                group = hfGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(hfGroup, nil, 2)
        else
            -- Threshold first, then the opacity it applies: the two numbers the
            -- feature IS, in the order the controls are in. The threshold is a
            -- percent and wears its sign; the opacity takes L["Alpha"]. Both are
            -- shown unconditionally: the feature is off on a default profile (a
            -- shut card then reads "Off"), so anyone reading this turned it on and
            -- wants the numbers.
            local function HealthFadeSummary(d)
                if not d then return "" end
                local parts = {}
                local t = tonumber(d.healthFadeThreshold)
                if t then parts[#parts + 1] = format("%d%%", math.floor(t)) end
                local a = tonumber(d.healthFadeAlpha)
                if a then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ THE ENABLE IS THE HEADER'S TICK, so the builder is told not to
            -- build its own (hoistToggle). The commit is what the in-body checkbox
            -- ran plus the state pass that greys the body -- never a page rebuild.
            -- How faded a healthy frame is is how it LOOKS, so it is pinnable.
            local band = OpenSection(L["Health Threshold Fading"], "fading_health", 2, HealthFadeSummary, nil, nil,
                BuildHealthFadeGroup, {
                    db = db, key = "healthFadeEnabled", label = L["Enable Health Threshold Fade"],
                    tooltip = L["Fade frames or elements when a unit's health is above the set threshold (e.g. 100% or 80%)."],
                    onChanged = function()
                        DF:UpdateAllFrames()
                        DF:RefreshAllVisibleFrames()
                        self:RefreshStates()
                        tools.ReflowMounted()
                    end,
                })
            BuildHealthFadeGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- ===== NO BAND TAIL ================================================
        -- A card's band holds one group and is Add'd by CloseSection the moment
        -- that group is built, so nothing is deferred to here. Out of Range down
        -- the left, the two feature fades down the right; on a narrow window the
        -- page folds to one column in the order above.

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
        
        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: ten 280 boxes in the two columns
        -- and the same order -- General, Layout Mode, Group Settings (grouped
        -- only), Size and Position (attached only) down column 1; Appearance,
        -- Border, Health Bar, Name Text and Health Text down column 2.
        --
        -- MODERN is the Debuff Bar's collapsible-card design, one card per box:
        -- two settings per row inside a card wide enough, dim captions, the value
        -- summary in a shut card's corner, Expand All / Collapse All at the top.
        --
        --   column 1   Pet Frame Settings (the PAGE gate, Enable Pet Frames, in
        --              its body); "Layout": Layout Mode, Group Settings (grouped
        --              only), Size, Position (attached only); "Text": Name Text,
        --              Health Text
        --   column 2   "Frame": Appearance, Border (Show Border is the header's
        --              tick), Health Bar
        --
        -- Every card but the first greys with the page gate. Border is the one
        -- card with a header tick -- the Frame page's Border card's shape -- so
        -- it now behaves like every other card rather than like a feature row.
        -- Pins on the eight cards that decide how the pets LOOK; Pet Frame
        -- Settings and Layout Mode are behaviour.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates } plus, where it matters, `popout` (a
        -- pinned panel's mount) and `hoistToggle`. The classic branch mounts the
        -- SAME builder into the box it always built --
        -- test_petframes_page_builders.lua pins the inventory of each one against
        -- the census taken before the move, in BOTH mode variants.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery. Its PROLOGUE closes any panel a previous
        -- build left standing and retires that build's holders, and it carries the
        -- section helper the card pages build with. nil in classic, which is what
        -- every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE SECTION: the Debuff Bar's helper (tools.OpenSection) and its two
        -- opt-ins, which every card here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ☠ THE PAGE GATE, ON THE CARDS. Every group on this page carries
        -- `disableChildrenOn = not petEnabled` and always has; those gates stay
        -- INSIDE the builders, so a card's body greys exactly as its box did. This
        -- greys the card HEADERS with it, as the whole classic page visibly dims.
        -- A pinned Border panel takes it as its toolkit's consumer gate too.
        --
        -- ☠ NO INDEX-1 REPAIR ANY MORE: DandersUI Sections' RefreshChildStates
        -- skips on the `isSectionHeader` mark now, not on the position, so a
        -- band's (or a pinned pane's) first control greys like the rest.
        local function PetsOffRow(d) return not (d or db).petEnabled end

        -- ☠ WHAT A GATING CONTROL'S CALLBACK COSTS. Five controls on this page
        -- (the two Match Owner ticks, the health colour mode, Show Power Bar and
        -- the power colour mode) re-gate a sibling. A classic box and a Modern
        -- card are both page widgets, so both take the page's state pass; a
        -- pinned panel (`popout`) reflows its own pane instead.
        --
        -- ★ NEITHER REBUILDS: every sibling these gate carries its gate as
        -- hideOn/disableOn, so the state pass is all a rebuild bought -- and the
        -- rebuild leaked the whole page per click.
        local function GateRefresh(tools2)
            if tools2.popout then
                tools2.refreshStates()
            else
                GUI.RelayoutCurrentPage()
            end
        end

        -- ☠ SIX VALUE TABLES AND ONE APPLY MOVED UP TO PAGE SCOPE, ABOVE EVERY
        -- BUILDER. They used to sit in the straight-line code beside the controls
        -- that read them, which was fine while the page WAS straight-line code.
        -- The builders are CLOSURES now, and a closure captures the upvalue that
        -- exists when it is CREATED -- so a builder declared above one of these
        -- would see nil rather than the table. The cards need them from outside
        -- the builders as well: a summary prints the dropdown's own words.
        local textAnchorValues = {
            TOPLEFT= L["Top Left"], TOP= L["Top"], TOPRIGHT= L["Top Right"],
            LEFT= L["Left"], CENTER= L["Center"], RIGHT= L["Right"],
            BOTTOMLEFT= L["Bottom Left"], BOTTOM= L["Bottom"], BOTTOMRIGHT= L["Bottom Right"],
        }

        local groupModeValues = {
            ATTACHED = L["Attached to Owner"],
            GROUPED = L["Separate Pet Group"],
        }

        -- Raid or party wording, exactly as the grouped block built it.
        local groupAnchorValues = {
            BOTTOM = isRaidMode and L["Below Raid"] or L["Below Party"],
            TOP = isRaidMode and L["Above Raid"] or L["Above Party"],
            LEFT = isRaidMode and L["Left of Raid"] or L["Left of Party"],
            RIGHT = isRaidMode and L["Right of Raid"] or L["Right of Party"],
        }
        local growthValues = { HORIZONTAL= L["Horizontal"], VERTICAL= L["Vertical"] }

        local anchorValues = {
            BOTTOM = L["Below Owner"],
            TOP = L["Above Owner"],
            LEFT = L["Left of Owner"],
            RIGHT = L["Right of Owner"],
        }

        local healthColorValues = {
            GREEN = L["Always Green"],
            CLASS = L["Class Color"],
            HEALTH = L["Health Gradient"],
            CUSTOM = L["Custom Color"],
        }
        local powerColorValues = {
            POWER = L["By Power Type"],
            CUSTOM = L["Custom Color"],
        }

        -- The grouped block's `updateFunc`, under a name, at page scope: the five
        -- controls in that group call it.
        local ApplyPetGroupLayout = isRaidMode
            and function() if DF.UpdateRaidPetGroupLayout then DF:UpdateRaidPetGroupLayout() end end
            or function() if DF.UpdatePetGroupLayout then DF:UpdatePetGroupLayout() end end

        -- ===== GENERAL GROUP (a 280 box in column 1 in classic, the first card
        -- in Modern) =====
        -- Verbatim, taking the group and parent it should build into: same
        -- factories, same L keys, same db keys, same callbacks, same slot heights.
        --
        -- ⚠ tools2.refreshStates, NOT self:RefreshStates. The enable gates every
        -- other group on this page, so in Modern it has to re-grey the cards AND
        -- any pinned panel standing open beside them. In classic the tools2 hook
        -- IS self:RefreshStates, so nothing changed there.
        local function BuildPetGeneralGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local petEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Pet Frames"], db, "petEnabled", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
                tools2.refreshStates()
            end), 30)
            petEnable.keepEnabled = true
            group.disableChildrenOn = function(d) return not d.petEnabled end
            -- No slot height on the blurbs here or in the group below: at 250 they
            -- wrap to more lines than they did at 530, and CreateLabel measures
            -- itself whenever the call site does not pin it. Guessing a replacement
            -- number by hand is what puts a blurb through the control beneath it.
            group:AddWidget(GUI:CreateLabel(parent, L["Show health bars for player and party/raid member pets, anchored to their owner's frame. Pet frames hide when owner dies."], 250))
        end

        -- ===== LAYOUT MODE GROUP (a 280 box in column 1 in classic, the first
        -- Layout card in Modern) =====
        local function BuildPetLayoutModeGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = function(d) return not d.petEnabled end

            -- ☠ GUI:RefreshCurrentPage IN BOTH LAYOUTS, and it is the one callback
            -- on this page that keeps it. The others rebuild to re-run a
            -- hideOn/disableOn pass, which a pane's own refresh does better; this
            -- one changes WHICH GROUPS EXIST -- Group Settings appears, Position
            -- disappears, two Match Owner ticks come and go, and two sliders swap
            -- their disableOn for nothing. No state pass produces widgets that
            -- were never built, so the rebuild is the work rather than a shortcut
            -- to it. The dropdown lives on the PAGE in both layouts, which is what
            -- makes that legal: a page widget expects to be retired by a rebuild,
            -- and the helper's prologue closing the open panels on the way in is
            -- the intended behaviour on a structural change, not a casualty of it.
            local petLayoutMode = group:AddWidget(GUI:CreateDropdown(parent, L["Layout Mode"], groupModeValues, db, "petGroupMode", function()
                if DF.UpdateAllPetFrames then DF:UpdateAllPetFrames(true) end
                if DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
                GUI:RefreshCurrentPage()
            end), 55)
            petLayoutMode.tooltip = L["Attached puts each pet beside its owner's frame, so you read them together. Separate Pet Group collects every pet into one block you can place anywhere. The rest of this page changes to match your choice."]

            if not isGroupedMode then
                group:AddWidget(GUI:CreateLabel(parent, L["Pet frames are positioned relative to their owner's frame."], 250))
            else
                group:AddWidget(GUI:CreateLabel(parent, L["Pet frames are grouped together in a separate container."], 250))
            end
        end

        if classicLayout then
            -- ===== GENERAL GROUP (col1) =====
            -- Column width, not full width. A full-width box belongs to a page that
            -- genuinely needs the room -- Pinned Frames, Nicknames -- and everything
            -- below these two here is ordinary two-column controls, so stretching
            -- them across the top reads as two different layouts stacked together.
            local generalGroup = GUI:CreateSettingsGroup(self.child, 280)
            generalGroup:AddWidget(GUI:CreateHeader(self.child, L["Pet Frame Settings"]), 40)
            BuildPetGeneralGroup({
                group = generalGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(generalGroup, nil, 1)

            -- ===== LAYOUT MODE GROUP (col1) =====
            local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
            layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout Mode"]), 40)
            BuildPetLayoutModeGroup({
                group = layoutGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(layoutGroup, nil, 1)
        else
            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Buff Bar's placement and its reasons: they act on cards in both
            -- columns, and "both" carries them through the one-column fold intact.
            Add(tools.SectionControls(self.child), 24, "both")

            -- ☠ ENABLE PET FRAMES STAYS IN THE BODY, as Show Buffs does on the
            -- Buff Bar: it is the PAGE gate, a fold is not a switch, and a header
            -- tick that greyed the whole page would surprise people. So the first
            -- card holds it and its blurb, and never greys itself. Its commit also
            -- repaints a pinned panel, whose own gate reads the same key.
            local settingsBand = OpenSection(L["Pet Frame Settings"], "pets_settings", 1, nil)
            BuildPetGeneralGroup({
                group = settingsBand, parent = self.child,
                refreshStates = function() self:RefreshStates() tools.ReflowMounted() end,
            })
            CloseSection(settingsBand)

            -- The category header the Layout cards sit under.
            Add(GUI:CreateHeader(self.child, L["Layout"]), 40, 1)
            -- ☠ LAYOUT MODE REBUILDS THE PAGE, in both layouts: picking a mode
            -- changes which cards exist at all (Group Settings, Position, the two
            -- Match Owner ticks). A card is a page widget and expects to be
            -- retired by a rebuild; its fold survives it (a stable key). Which
            -- layout the pets use is behaviour, so no pin -- and a pinned copy of
            -- a control that rebuilds the page would close under the hand anyway.
            local modeBand = OpenSection(L["Layout Mode"], "pets_layoutmode", 1, nil, PetsOffRow)
            BuildPetLayoutModeGroup({
                group = modeBand, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(modeBand)
        end

        -- ===== GROUP SETTINGS (grouped mode only: a 280 box in column 1 in
        -- classic, a Layout card in Modern) =====
        -- Built only in GROUPED mode, exactly as today. The page rebuilds when the
        -- layout mode changes, so the card simply is not there in attached mode --
        -- which is what the box did, and what keeps the two layouts agreeing about
        -- what exists.
        local function BuildPetGroupSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = function(d) return not d.petEnabled end

            local petGroupPos = group:AddWidget(GUI:CreateDropdown(parent, L["Group Position"], groupAnchorValues, db, "petGroupAnchor", ApplyPetGroupLayout), 55)
            petGroupPos.tooltip = L["Which side of your party or raid frames the whole pet block sits on. Use the offsets below to nudge it from there."]

            group:AddWidget(GUI:CreateDropdown(parent, L["Growth Direction"], growthValues, db, "petGroupGrowth", ApplyPetGroupLayout), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Spacing"], 0, 20, 1, db, "petGroupSpacing", ApplyPetGroupLayout, ApplyPetGroupLayout, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Group X Offset"], -100, 100, 1, db, "petGroupOffsetX", ApplyPetGroupLayout, ApplyPetGroupLayout, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Group Y Offset"], -100, 100, 1, db, "petGroupOffsetY", ApplyPetGroupLayout, ApplyPetGroupLayout, true), 55)

            if isRaidMode then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Group Label"], db, "petGroupShowLabel", function()
                    if DF.UpdateRaidPetGroupLayout then DF:UpdateRaidPetGroupLayout() end
                end), 30)
            end
        end

        if isGroupedMode then
            if classicLayout then
                -- GROUPED MODE: Group Settings (col1)
                local groupedSettingsGroup = GUI:CreateSettingsGroup(self.child, 280)
                groupedSettingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Group Settings"]), 40)
                BuildPetGroupSettingsGroup({
                    group = groupedSettingsGroup,
                    parent = self.child,
                    refreshStates = function() self:RefreshStates() end,
                })
                Add(groupedSettingsGroup, nil, 1)
            else
                -- Where the block sits, which way it grows, and the nudge -- the
                -- three facts that place it. Both words come out of the
                -- dropdowns' own option tables. Spacing is deliberately absent:
                -- a bare number with no word that fits beside two others.
                local function PetGroupSummary(d)
                    if not d then return "" end
                    local parts = {}
                    local pos = groupAnchorValues[d.petGroupAnchor]
                    if pos then parts[#parts + 1] = pos end
                    local growth = growthValues[d.petGroupGrowth]
                    if growth then parts[#parts + 1] = growth end
                    local ox = tonumber(d.petGroupOffsetX) or 0
                    local oy = tonumber(d.petGroupOffsetY) or 0
                    if ox ~= 0 or oy ~= 0 then
                        parts[#parts + 1] = format("%d, %d", math.floor(ox), math.floor(oy))
                    end
                    return table.concat(parts, " \194\183 ")
                end

                -- Grouped mode only, exactly as the box. Where the pet block sits
                -- and how it is spaced is how it LOOKS, so it is pinnable; greys
                -- with the page gate.
                local band = OpenSection(L["Group Settings"], "pets_group", 1, PetGroupSummary, PetsOffRow, nil,
                    BuildPetGroupSettingsGroup)
                BuildPetGroupSettingsGroup({
                    group = band, parent = self.child,
                    refreshStates = function() self:RefreshStates() end,
                })
                CloseSection(band)
            end
        end

        -- ===== SIZE (a 280 box in column 1 in classic, a Layout card in Modern)
        -- =====
        local function BuildPetSizeGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = function(d) return not d.petEnabled end

            if not isGroupedMode then
                local petMatchW = group:AddWidget(GUI:CreateCheckbox(parent, L["Match Owner Width"], db, "petMatchOwnerWidth", function()
                    if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
                    GateRefresh(tools2)
                end), 30)
                petMatchW.tooltip = L["Sizes each pet frame to its owner's, so the pair stays aligned when you resize the unit frames. The Width slider below greys out while this is on."]
                local petMatchH = group:AddWidget(GUI:CreateCheckbox(parent, L["Match Owner Height"], db, "petMatchOwnerHeight", function()
                    if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
                    GateRefresh(tools2)
                end), 30)
                petMatchH.tooltip = L["Sizes each pet frame to its owner's, so the pair stays aligned when you resize the unit frames. The Height slider below greys out while this is on."]
            end

            local widthSlider = group:AddWidget(GUI:CreateSlider(parent, L["Width"], 40, 150, 1, db, "petFrameWidth", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            if not isGroupedMode then
                widthSlider.disableOn = function(d) return d.petMatchOwnerWidth end
            end

            local heightSlider = group:AddWidget(GUI:CreateSlider(parent, L["Height"], 10, 40, 1, db, "petFrameHeight", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            if not isGroupedMode then
                heightSlider.disableOn = function(d) return d.petMatchOwnerHeight end
            end
        end

        if classicLayout then
            -- SIZE GROUP (col1)
            local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
            sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Size"]), 40)
            BuildPetSizeGroup({
                group = sizeGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(sizeGroup, nil, 1)
        else
            -- ⚠ A NUMBER ONLY WHERE IT IS THE NUMBER IN USE. In attached mode
            -- either dimension can be handed to the owner's frame, and
            -- petMatchOwnerWidth ships ON -- so printing "Width 130" on a default
            -- profile would name a value nothing renders. The matched half is
            -- simply absent. In grouped mode neither tick exists and both numbers
            -- are always the real ones.
            local function PetSizeSummary(d)
                if not d then return "" end
                local parts = {}
                local attached = d.petGroupMode ~= "GROUPED"
                if not (attached and d.petMatchOwnerWidth) then
                    local w = tonumber(d.petFrameWidth)
                    if w then parts[#parts + 1] = format("%s %d", L["Width"], math.floor(w)) end
                end
                if not (attached and d.petMatchOwnerHeight) then
                    local h = tonumber(d.petFrameHeight)
                    if h then parts[#parts + 1] = format("%s %d", L["Height"], math.floor(h)) end
                end
                return table.concat(parts, " \194\183 ")
            end

            -- No tick: a pet frame has a size either way. How big the pet frame
            -- is is how it LOOKS, so it is pinnable; greys with the page gate.
            local band = OpenSection(L["Size"], "pets_size", 1, PetSizeSummary, PetsOffRow, nil,
                BuildPetSizeGroup)
            BuildPetSizeGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== APPEARANCE (a 280 box in column 2 in classic, the first Frame
        -- card in Modern) =====
        local function BuildPetAppearanceGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = function(d) return not d.petEnabled end

            group:AddWidget(GUI:CreateTextureDropdown(parent, L["Health Bar Texture"], db, "petTexture", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            group:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], db, "petBackgroundColor", true, function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        end

        if classicLayout then
            -- APPEARANCE GROUP (col2)
            local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
            appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
            BuildPetAppearanceGroup({
                group = appearanceGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(appearanceGroup, nil, 2)
        else
            -- The texture's NAME, and nothing else: it is the one thing in this
            -- group that can be said in words, and a background colour cannot.
            -- The name comes from DF:GetTextureNameFromPath -- the resolver
            -- GUI:CreateTextureDropdown itself prints on its button, so the
            -- card and the control inside it cannot disagree.
            local function PetAppearanceSummary(d)
                if not d then return "" end
                local parts = {}
                local name = DF.GetTextureNameFromPath and DF:GetTextureNameFromPath(d.petTexture)
                if type(name) == "string" and name ~= "" then parts[#parts + 1] = name end
                return table.concat(parts, " \194\183 ")
            end

            -- Column 2 opens here, with the category header its three cards sit
            -- under. How the frame LOOKS, so it is pinnable; greys with the page
            -- gate.
            Add(GUI:CreateHeader(self.child, L["Frame"]), 40, 2)
            local band = OpenSection(L["Appearance"], "pets_appearance", 2, PetAppearanceSummary, PetsOffRow, nil,
                BuildPetAppearanceGroup)
            BuildPetAppearanceGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== BORDER (a 280 box in column 2 in classic, the second Frame card
        -- in Modern) =====
        -- include set tailored for a mini unit frame's border. Skipped:
        -- animate (decoration, not alert), offset (Pet Frame has its own
        -- Offset X / Y in the Position group in column 1), class / role colour
        -- (UnitClass("pet") returns the pet family, not a class token),
        -- colour-by-time / colour-by-type (no aura-state context).
        --
        -- ONE call, not the Frame page's two. That page splits Border and Border
        -- Shadow into two cards because between them they are nineteen controls;
        -- here the whole border is sixteen, of which the shadow is five, and a
        -- card for five sub-controls of another card's feature is a level of
        -- nesting the page does not earn. include.shadow keeps the shadow block
        -- inside CreateBorderControls' own composition loop, which is what puts
        -- Show Border's grey on top of it -- so this card needs no
        -- shadowDisableWhen plumbing at all.
        --
        -- ⚠ noShowToggle IS THE HEADER TICK. With it the built-in Show Border
        -- checkbox is not built and the card's header carries that tick instead;
        -- showKey is still read, so borderOff still greys the other fifteen.
        local function BuildPetBorderGroup(tools2)
            GUI:CreateBorderControls(tools2.group, db, "pet", {
                parent       = tools2.parent,
                include      = { alpha = true, inset = true, blendMode = true,
                                 gradient = true, shadow = true },
                fullUpdate   = function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end,
                lightUpdate  = function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end,
                lightColors  = function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end,
                refreshStates = tools2.refreshStates,
                sizeMin = 1, sizeMax = 6, sizeStep = 1,
                noShowToggle = tools2.hoistToggle or nil,
                -- ☠ THE PAGE GATE, THROUGH THE FACTORY'S OWN DOOR. Every other
                -- builder on this page greys behind petEnabled with
                -- group.disableChildrenOn; this one cannot, because
                -- CreateBorderControls owns the group and writes disableOn onto
                -- each of the sixteen itself -- so the gate goes in as the
                -- CONSUMER gate it is, which the factory composes on top of
                -- borderOff and every widget's own predicate. nil on the page --
                -- the classic box and the Modern card both carry the gate as
                -- their own disableChildrenOn, set before this runs -- so only a
                -- pinned panel's mount (tools2.popout) takes it here.
                disableWhen  = tools2.popout and PetsOffRow or nil,
            })
        end

        -- What the suppressed Show Border checkbox's toolkit ran: the lightweight
        -- pass every border control drives. The header tick's commit calls it.
        local function ApplyPetBorder()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end

        if classicLayout then
            -- ===== BORDER GROUP (col2) =====
            local petBorderGroup = GUI:CreateSettingsGroup(self.child, 280)
            petBorderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
            petBorderGroup.disableChildrenOn = function(d) return not d.petEnabled end
            BuildPetBorderGroup({
                group = petBorderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(petBorderGroup, nil, 2)
        else
            -- The Frame page's Border summary, less the colour source it has and
            -- this one does not: thickness in pixels, the style word, and the
            -- alpha only when it is doing something.
            local function PetBorderSummary(d)
                if not d then return "" end
                local parts = {}
                local size = tonumber(d.petBorderSize)
                if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
                local style = d.petBorderStyle
                parts[#parts + 1] = (style == "GRADIENT" and L["Gradient"])
                                 or (style == "TEXTURE" and L["Texture"])
                                 or L["Solid"]
                local c = d.petBorderColor
                local a = type(c) == "table" and tonumber(c.a) or nil
                if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ SHOW BORDER IS THE HEADER'S TICK, so the toolkit is told not to
            -- build its own (hoistToggle -> noShowToggle); showKey is still read,
            -- so the other fifteen grey exactly as before. The commit is what the
            -- in-body checkbox ran plus a state pass and a repaint of a pinned
            -- panel -- never a page rebuild. The tick greys with the page gate.
            --
            -- ⚠ THE PAGE GATE ON THE BODY IS THE CLASSIC BOX'S OWN LINE. The
            -- toolkit owns the group and writes disableOn onto each control, so
            -- the builder takes the page gate as the consumer gate only when it
            -- is mounted in a pinned panel (tools2.popout); on the page the band
            -- carries the group gate, set before the build, exactly as classic
            -- sets it on its box. How the border LOOKS, so it is pinnable.
            local band = OpenSection(L["Border"], "pets_border", 2, PetBorderSummary, PetsOffRow, nil,
                BuildPetBorderGroup, {
                    db = db, key = "petShowBorder", label = L["Show Border"],
                    disableOn = PetsOffRow,
                    onChanged = function()
                        ApplyPetBorder()
                        self:RefreshStates()
                        tools.ReflowMounted()
                    end,
                })
            band.disableChildrenOn = function(d) return not d.petEnabled end
            BuildPetBorderGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- ===== HEALTH BAR (a 280 box in column 2 in classic, the third Frame
        -- card in Modern) =====
        local function BuildPetHealthBarGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = function(d) return not d.petEnabled end

            group:AddWidget(GUI:CreateDropdown(parent, L["Health Bar Color"], healthColorValues, db, "petHealthColorMode", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
                GateRefresh(tools2)
            end), 55)

            local customHealthColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Custom Health Color"], db, "petHealthColor", false, function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
            customHealthColor.hideOn = function(d) return d.petHealthColorMode ~= "CUSTOM" end

            group:AddWidget(GUI:CreateCheckbox(parent, L["Show Health Percentage"], db, "petShowHealthText", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end), 30)

            group:AddWidget(GUI:CreateCheckbox(parent, L["Show Power Bar"], db, "petShowPowerBar", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
                GateRefresh(tools2)
            end), 30)

            local petPowerHeight = group:AddWidget(GUI:CreateSlider(parent, L["Power Bar Height"], 1, 12, 1, db, "petPowerBarHeight", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            petPowerHeight.disableOn = function(d) return not d.petShowPowerBar end  -- grey when power bar off

            local petPowerColorMode = group:AddWidget(GUI:CreateDropdown(parent, L["Power Bar Color"], powerColorValues, db, "petPowerColorMode", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
                GateRefresh(tools2)
            end), 55)
            petPowerColorMode.disableOn = function(d) return not d.petShowPowerBar end  -- grey when power bar off

            local customPowerColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Custom Power Color"], db, "petPowerColor", false, function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
            -- Grey when the power bar is off (boolean fold); HIDE only for the non-CUSTOM
            -- colour mode (variant gating). The two compose: hidden in non-CUSTOM, greyed
            -- in CUSTOM while the power bar is off.
            customPowerColor.disableOn = function(d) return not d.petShowPowerBar end
            customPowerColor.hideOn = function(d) return d.petPowerColorMode ~= "CUSTOM" end
        end

        if classicLayout then
            -- HEALTH BAR GROUP (col2)
            local healthBarGroup = GUI:CreateSettingsGroup(self.child, 280)
            healthBarGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Bar"]), 40)
            BuildPetHealthBarGroup({
                group = healthBarGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(healthBarGroup, nil, 2)
        else
            -- What colour the bar is, then whether there is a second bar under it.
            -- Both in the controls' own words: the colour mode out of the
            -- dropdown's option table, the power bar out of its checkbox's label,
            -- and the power bar only when it is on.
            --
            -- ⚠ NO HEADER TICK. Show Power Bar is the only boolean in the group
            -- and it governs three of the seven controls; in the header it would
            -- claim to speak for the four health-bar settings it has nothing to do
            -- with, and a card switched off would grey a health bar that is always
            -- drawn.
            local function PetHealthBarSummary(d)
                if not d then return "" end
                local parts = {}
                local mode = healthColorValues[d.petHealthColorMode]
                if mode then parts[#parts + 1] = mode end
                if d.petShowPowerBar then parts[#parts + 1] = L["Show Power Bar"] end
                return table.concat(parts, " \194\183 ")
            end

            -- How the bar LOOKS, so it is pinnable; greys with the page gate.
            local band = OpenSection(L["Health Bar"], "pets_healthbar", 2, PetHealthBarSummary, PetsOffRow, nil,
                BuildPetHealthBarGroup)
            BuildPetHealthBarGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== NAME TEXT (a 280 box in column 2 in classic, the first Text card
        -- in Modern -- opened after Position, see NAME TEXT, AS A CARD) =====
        local function BuildPetNameTextGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = function(d) return not d.petEnabled end

            group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], db, "petNameFont", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Font Size"], 6, 16, 1, db, "petNameFontSize", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], db, "petNameFontOutline", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], db, "petNameFontOutline", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 30)
            group:AddWidget(GUI:CreateSlider(parent, L["Max Name Length"], 4, 20, 1, db, "petNameMaxLength", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end), 55)
            group:AddWidget(GUI:CreateDropdown(parent, L["Name Anchor"], textAnchorValues, db, "petNameAnchor", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            group:AddWidget(GUI:CreateColorPicker(parent, L["Name Text Color"], db, "petNameColor", false, function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
            group:AddWidget(GUI:CreateSlider(parent, L["Name X Offset"], -30, 30, 1, db, "petNameX", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Name Y Offset"], -15, 15, 1, db, "petNameY", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        end

        -- Both text rows print the same three facts in the same order: the font,
        -- its size, and where the text sits. The NAME comes from
        -- DF:GetFontNameFromPath -- the addon's own font display-name resolver,
        -- and the one GUI:CreateFontDropdown itself prints on its button, so the
        -- row and the control behind it cannot disagree. The anchor word comes out
        -- of the very table the dropdown offers. One factory, because the two
        -- groups differ only in their key prefix.
        local function TextRowSummary(fontKey, sizeKey, anchorKey)
            return function(d)
                if not d then return "" end
                local parts = {}
                local fontName = DF.GetFontNameFromPath and DF:GetFontNameFromPath(d[fontKey])
                if type(fontName) == "string" and fontName ~= "" then
                    parts[#parts + 1] = fontName
                end
                local size = tonumber(d[sizeKey])
                if size then parts[#parts + 1] = format("%d", math.floor(size)) end
                local anchor = textAnchorValues[d[anchorKey]]
                if anchor then parts[#parts + 1] = anchor end
                return table.concat(parts, " \194\183 ")
            end
        end

        if classicLayout then
            -- NAME TEXT GROUP (col2)
            local nameTextGroup = GUI:CreateSettingsGroup(self.child, 280)
            nameTextGroup:AddWidget(GUI:CreateHeader(self.child, L["Name Text"]), 40)
            BuildPetNameTextGroup({
                group = nameTextGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(nameTextGroup, nil, 2)
        end
        -- (Modern builds the Name Text card further down, after Position -- see
        -- NAME TEXT, AS A CARD.)

        -- ===== POSITION (attached mode only: a 280 box in column 1 in classic,
        -- the last Layout card in Modern) =====
        -- Built only in ATTACHED mode, exactly as today -- in grouped mode there
        -- is no owner to sit beside and the Group Settings card owns the
        -- placement instead.
        local function BuildPetPositionGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = function(d) return not d.petEnabled end

            -- ☠ LightweightUpdatePetFrames, NOT UpdateAllPetFramePositions: the
            -- latter branches only on the LIVE tracks (party/raid/arena), so in
            -- test mode these controls silently did nothing on keyboard entry —
            -- mouse drags only "worked" because drag-release runs a full update
            -- that happens to cover test pets (#1047). The lightweight pass is
            -- track-aware, test modes included.
            group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorValues, db, "petAnchor", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -50, 50, 1, db, "petOffsetX", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -50, 50, 1, db, "petOffsetY", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        end

        if not isGroupedMode then
            if classicLayout then
                -- POSITION GROUP (col1, Attached mode only)
                local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
                positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
                BuildPetPositionGroup({
                    group = positionGroup,
                    parent = self.child,
                    refreshStates = function() self:RefreshStates() end,
                })
                Add(positionGroup, nil, 1)
            else
                -- Which side of the owner, then the nudge -- the Group Settings
                -- card's shape, in the owner's words rather than the raid's. The
                -- offsets are printed as a pair when either is set; petOffsetY
                -- ships at -1, so a default profile shows both facts.
                local function PetPositionSummary(d)
                    if not d then return "" end
                    local parts = {}
                    local anchor = anchorValues[d.petAnchor]
                    if anchor then parts[#parts + 1] = anchor end
                    local ox = tonumber(d.petOffsetX) or 0
                    local oy = tonumber(d.petOffsetY) or 0
                    if ox ~= 0 or oy ~= 0 then
                        parts[#parts + 1] = format("%d, %d", math.floor(ox), math.floor(oy))
                    end
                    return table.concat(parts, " \194\183 ")
                end

                -- The last Layout card. Where the pet sits is how it LOOKS, so it
                -- is pinnable; greys with the page gate.
                local band = OpenSection(L["Position"], "pets_position", 1, PetPositionSummary, PetsOffRow, nil,
                    BuildPetPositionGroup)
                BuildPetPositionGroup({
                    group = band, parent = self.child,
                    refreshStates = function() self:RefreshStates() end,
                })
                CloseSection(band)
            end
        end

        -- ===== NAME TEXT, AS A CARD (Modern only) ==========================
        -- ☠ ADDED HERE, AFTER POSITION, NOT WHERE ITS BUILDER SITS. A card goes
        -- into its column the moment CloseSection runs, so the order cards are
        -- built in IS the order they stack in. Name Text heads the Text cards
        -- in column 1, which has to be below the Layout cards -- Position
        -- included -- so it is opened here rather than beside its classic box.
        -- How the name LOOKS, so it is pinnable; greys with the page gate.
        if not classicLayout then
            Add(GUI:CreateHeader(self.child, L["Text"]), 40, 1)
            local band = OpenSection(L["Name Text"], "pets_nametext", 1,
                TextRowSummary("petNameFont", "petNameFontSize", "petNameAnchor"), PetsOffRow, nil,
                BuildPetNameTextGroup)
            BuildPetNameTextGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== HEALTH TEXT (a 280 box in column 2 in classic, the second Text
        -- card in Modern) =====
        local function BuildPetHealthTextGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = function(d) return not d.petEnabled end

            group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], db, "petHealthFont", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Font Size"], 6, 14, 1, db, "petHealthFontSize", function()
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], db, "petHealthFontOutline", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], db, "petHealthFontOutline", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 30)
            group:AddWidget(GUI:CreateColorPicker(parent, L["Health Text Color"], db, "petHealthTextColor", false, function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
            group:AddWidget(GUI:CreateDropdown(parent, L["Health Text Anchor"], textAnchorValues, db, "petHealthAnchor", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Health X Offset"], -30, 30, 1, db, "petHealthX", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Health Y Offset"], -15, 15, 1, db, "petHealthY", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
            end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        end

        if classicLayout then
            -- HEALTH TEXT GROUP (col2)
            local healthTextGroup = GUI:CreateSettingsGroup(self.child, 280)
            healthTextGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Text"]), 40)
            BuildPetHealthTextGroup({
                group = healthTextGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(healthTextGroup, nil, 2)
        else
            -- The second Text card, under Name Text in column 1. The font, its
            -- size and where the text sits -- TextRowSummary's three facts. How
            -- the text LOOKS, so it is pinnable; greys with the page gate.
            local band = OpenSection(L["Health Text"], "pets_healthtext", 1,
                TextRowSummary("petHealthFont", "petHealthFontSize", "petHealthAnchor"), PetsOffRow, nil,
                BuildPetHealthTextGroup)
            BuildPetHealthTextGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== NO BAND TAIL ================================================
        -- A card's band holds one group and is Add'd by CloseSection the moment
        -- that group is built, so nothing is deferred to here. Settings, Layout
        -- and Text down the left, Frame down the right; on a narrow window the
        -- page folds to one column in the order the cards were added.
        --
        -- ⚠ TEXT IS LEFT FOR BALANCE, as the bands had it. The rule would put it
        -- with Frame, but Layout is two or three cards and Frame's Border alone is
        -- fifteen controls.
    end)
    
    -- General > Settings (mode enable/disable, Blizzard frame toggles, profile-wide settings)
    local pageGeneral = CreateSubTab("general", "general_settings", L["Settings"])
    BuildPage(pageGeneral, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Helpers: read from party-mode storage (canonical), write to BOTH
        -- party and raid mode dbs so the value stays consistent regardless
        -- of which mode is currently selected. The Blizzard frames are
        -- global UI elements so the toggle conceptually has no mode.
        --
        -- ☠ THESE STAY AT PAGE SCOPE, in both layouts. Three of the builders
        -- below are bound to them, the classic box, the card and a pinned copy
        -- must drive the SAME setter, and neither closes over anything
        -- group-specific.
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

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: seven 280 boxes under the info
        -- banner, four in column one and three in column two. MODERN makes each
        -- of the seven a collapsible card (see THE PAGE'S CARDS, below the
        -- banner).
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates }. The classic branch mounts the SAME
        -- builder into the box it always built --
        -- test_settings_page_builders.lua pins the inventory of each one against
        -- the census taken before the move.
        --
        -- ☠☠ THIS PAGE OWNS NOT ONE PLAIN PER-MODE PROFILE KEY, and every
        -- summary and every store below follows from it:
        --
        --   * partyEnabled / raidEnabled / settingsFont / settingsFontOutline sit
        --     at the DF.db ROOT -- profile-wide, not per mode;
        --   * the four Blizzard toggles, the minimap button and Pixel-Perfect
        --     Scaling ARE stored per mode, but they are read party-canonical and
        --     written to BOTH tables through makeBlizSet;
        --   * the aura update rate and the two notification ticks are
        --     account-wide (DF:GetGlobalDB());
        --   * the language override lives on the per-character SavedVariable;
        --   * "Use classic settings layout" is an account-level flag with no db
        --     table at all.
        --
        -- So a card's summary, which the page's state pass hands the PER-MODE
        -- table, reads the store its own keys live in instead of what it was
        -- handed. And no reset of any kind may be wired here: DF.Defaults
        -- answers for the per-mode tables only, a per-mode write would desync
        -- the pair makeBlizSet keeps together, and two of these groups need a UI
        -- RELOAD to take effect.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery. Its PROLOGUE closes any panel a previous
        -- build left standing and retires that build's holders, and it carries the
        -- section helper the card pages build with. nil in classic, which is what
        -- every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ===== INFO BANNER (global settings notice) =====
        -- Untouched by the conversion and still the first thing on the page: it
        -- is the sentence that explains why none of this has a party/raid split,
        -- and a banner folded behind a click would be a warning nobody reads.
        do
            local banner = GUI:CreateInfoBanner(self.child, {
                tone = "info",
                text = L["Settings on this page apply globally — changes persist across both the Party and Raid sections."],
            })
            Add(banner, banner.layoutHeight, "both")
        end

        -- ===== THE PAGE'S CARDS (Modern) ==================================
        -- The Debuff Bar's collapsible-card design, one card per classic box: two
        -- settings per row inside a card wide enough, dim captions, the value
        -- summary in a shut card's corner, Expand All / Collapse All at the top.
        -- The two bands the page was split into are kept as its two columns:
        --
        --   column 1   Frame Modes, Blizzard Frames, Notifications -- what the
        --              addon DOES
        --   column 2   Rendering, Settings Panel Appearance -- how things LOOK --
        --              then Minimap and Language, each its classic box as a card
        --
        -- No header ticks: every group here is independent switches, not one
        -- feature's on/off. Pins on Rendering and Settings Panel Appearance.
        -- No category headers -- a header would mean inventing a name the
        -- classic page never had; the info banner says what is true of it all.
        --
        -- ONE SECTION: the Debuff Bar's helper (tools.OpenSection) and its two
        -- opt-ins, which every card here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ☠ THE PAGE'S TWO BULK VERBS, under the banner and above every card, at
        -- col "both" -- the Buff Bar's placement and its reasons.
        if not classicLayout then
            Add(tools.SectionControls(self.child), 24, "both")
        end

        -- ===== FRAME MODES (a 280 box in classic, the first card in Modern) ==
        -- Verbatim, taking the group and parent it should build into: same
        -- factories, same L keys, same db table and keys, same callbacks, same
        -- slot heights.
        --
        -- ⚠ NO TOGGLE IS HOISTED, and there are two candidates. Neither tick means
        -- "am I doing anything": Enable Party Frames and Enable Raid Frames are two
        -- INDEPENDENT modes and either can be off without the other, so a row that
        -- hoisted one would be claiming it speaks for the pair. That is the
        -- Integrations row's rule about its two colour-picker overrides.
        local function BuildFrameModesGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Party Frames"], DF.db, "partyEnabled", function() PromptReloadAfterModeToggle("party") end), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Raid Frames"], DF.db, "raidEnabled", function() PromptReloadAfterModeToggle("raid") end), 30)
            group:AddWidget(GUI:CreateLabel(parent,
                L["Completely enable or disable the Party or Raid frame system. Disabled modes are never created, consuming zero performance in the background. Requires a UI reload to apply."],
                260), 80)
        end

        if classicLayout then
            -- ===== FRAME MODES GROUP (Column 1, Top) =====
            local modesGroup = GUI:CreateSettingsGroup(self.child, 280)
            modesGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Modes"]), 40)
            BuildFrameModesGroup({
                group = modesGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(modesGroup, nil, 1)
        else
            -- The summary says the one thing on this page worth saying at a
            -- glance, and only while it is true: which mode is switched OFF. Both
            -- on is the shipped state and prints nothing.
            --
            -- ⚠ `== false`, NOT `not d.partyEnabled`. ABSENT MEANS ENABLED for
            -- these two keys, so a profile that has not been seeded yet would
            -- otherwise be reported as having both modes off.
            local function FrameModesSummary(d)
                if not d then return "" end
                local parts = {}
                if d.partyEnabled == false then parts[#parts + 1] = format("%s %s", L["Party"], L["Off"]) end
                if d.raidEnabled  == false then parts[#parts + 1] = format("%s %s", L["Raid"],  L["Off"]) end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ THE PROFILE ROOT, NOT THE PAGE'S TABLE. A card's summary is handed
            -- the per-mode db; partyEnabled / raidEnabled live at DF.db itself, and
            -- a summary reading the per-mode table would print nothing whatever
            -- the user had set.
            --
            -- ⚠ NO HEADER TICK: two INDEPENDENT modes, either can be off without
            -- the other. Behaviour, so no pin.
            local band = OpenSection(L["Frame Modes"], "general_framemodes", 1,
                function() return FrameModesSummary(DF.db) end)
            BuildFrameModesGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== BLIZZARD FRAMES (a 280 box in classic, a card in Modern) =====
        -- Storage stays per-mode (party + raid both updated via setter sync)
        -- so AutoProfiles and ExportCategories continue to work unchanged.
        --
        -- Verbatim, taking the group and parent it should build into -- the four
        -- ticks, their tooltips, the separator and the side-menu disableOn, in the
        -- same order at the same slot heights.
        --
        -- ⚠ NO TOGGLE IS HOISTED here either, for the Frame Modes reason twice
        -- over: these are four independent switches over three different Blizzard
        -- frames plus a sub-option, and none of them is the group's "am I doing
        -- anything".
        local function BuildBlizzardFramesGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local disablePartyCheck = group:AddWidget(GUI:CreateCheckbox(
                parent, L["Disable Blizzard Party Frames"],
                DF.db.party, "hideBlizzardPartyFrames",
                function() PromptReloadBlizzard() end,
                makeBlizGet("hideBlizzardPartyFrames"),
                makeBlizSet("hideBlizzardPartyFrames", function() DF:UpdateBlizzardFrameVisibility() end)
            ), 30)
            disablePartyCheck.tooltip = L["Hides and unregisters all events on the default Blizzard party frames so they consume no performance."]

            local disableRaidCheck = group:AddWidget(GUI:CreateCheckbox(
                parent, L["Disable Blizzard Raid Frames"],
                DF.db.party, "hideBlizzardRaidFrames",
                function() PromptReloadBlizzard() end,
                makeBlizGet("hideBlizzardRaidFrames"),
                makeBlizSet("hideBlizzardRaidFrames", function() DF:UpdateBlizzardFrameVisibility() end)
            ), 30)
            disableRaidCheck.tooltip = L["Hides and unregisters all events on the default Blizzard raid frames so they consume no performance."]

            local disablePlayerCheck = group:AddWidget(GUI:CreateCheckbox(
                parent, L["Hide Blizzard Player Frame"],
                nil, nil,
                function() DF:UpdateDefaultPlayerFrame() end,
                makeBlizGet("hideDefaultPlayerFrame"),
                makeBlizSet("hideDefaultPlayerFrame", function() DF:UpdateDefaultPlayerFrame() end),
                "hideDefaultPlayerFrame"
            ), 30)
            disablePlayerCheck.tooltip = L["Hides the default Blizzard player portrait and health bar."]

            -- Visual divider to separate the related sub-option (Show Side Menu only
            -- applies once a Blizzard frame is disabled).
            group:AddWidget(GUI:CreateSeparator(parent), 14)

            local sideMenuCheck = group:AddWidget(GUI:CreateCheckbox(
                parent, L["Show Party/Raid Side Menu"],
                DF.db.party, "showBlizzardSideMenu",
                function() PromptReloadBlizzard() end,
                makeBlizGet("showBlizzardSideMenu"),
                makeBlizSet("showBlizzardSideMenu", function() DF:UpdateBlizzardFrameVisibility() end)
            ), 30)
            -- ⚠ STAYS INSIDE THE BUILDER. In classic this greys the side-menu tick
            -- in the box; the card has to do the same, and one builder serving both
            -- is what stops the two drifting.
            --
            -- ⚠ IN THE PANE IT IS ONE REFRESH BEHIND, and that is an accepted trade
            -- rather than an oversight. The grey is applied by the group's
            -- RefreshChildStates, which the checkbox factory reaches implicitly
            -- through `parent:RefreshStates()` -- and the parent is the page child
            -- in classic (which forwards to the page) but a bare popout holder in a
            -- pane, which has no such method. Repairing it means appending a
            -- refreshStates call to the two Disable Blizzard * callbacks, i.e.
            -- editing a reload-popup callback this pass is not allowed to touch --
            -- and both of those settings put a "reload required" prompt on screen
            -- the moment they are clicked, so the panel behind it is about to be
            -- rebuilt anyway. The next reflow (or reopening the row) puts it right.
            sideMenuCheck.disableOn = function()
                local p = DF.db.party
                return not (p and (p.hideBlizzardPartyFrames or p.hideBlizzardRaidFrames))
            end
            sideMenuCheck.tooltip = L["Shows the ping wheel & party management menu when Blizzard frames are disabled."]
        end

        if classicLayout then
            -- ===== BLIZZARD FRAMES GROUP (Column 1, Bottom) =====
            local blizzardGroup = GUI:CreateSettingsGroup(self.child, 280)
            blizzardGroup:AddWidget(GUI:CreateHeader(self.child, L["Blizzard Frames"]), 40)
            BuildBlizzardFramesGroup({
                group = blizzardGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(blizzardGroup, nil, 1)
        else
            -- ☠ NO SUMMARY, and it is a judgement rather than a gap: every honest
            -- phrasing needs a word for the DIRECTION (these ticks HIDE things),
            -- and the only words the locale has for the frames are L["Party"] and
            -- L["Raid"] -- which Frame Modes above prints about the OPPOSITE
            -- state. Four independent switches, so no header tick; behaviour, so
            -- no pin.
            local band = OpenSection(L["Blizzard Frames"], "general_blizzard", 1, nil)
            BuildBlizzardFramesGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== MINIMAP (Column 1 in classic; a card near the foot in Modern) ==
        -- The minimap button is a single global UI element (no mode), so it lives
        -- here rather than the per-mode Visibility page. Reads party-canonical and
        -- writes both dbs so it stays consistent regardless of selected mode.
        -- Modern builds its card at the foot of the page -- see MINIMAP AND
        -- LANGUAGE, AS CARDS.
        if classicLayout then
            local minimapGroup = GUI:CreateSettingsGroup(self.child, 280)
            minimapGroup:AddWidget(GUI:CreateHeader(self.child, L["Minimap"]), 40)
            minimapGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Minimap Button"], nil, nil, function()
                DF:UpdateMinimapButton()
            end, makeBlizGet("showMinimapButton"), makeBlizSet("showMinimapButton"), "showMinimapButton"), 30)
            Add(minimapGroup, nil, 1)
        end

        -- ===== RENDERING (a 280 box in classic, a card in Modern) ===========
        -- Pixel-Perfect Scaling is a render-quality flag read by every frame and
        -- element in BOTH modes (Frames/Core.lua GetPixelScale + 60-odd db.pixelPerfect
        -- reads), so it's global — read party-canonical, write both mode dbs (same
        -- pattern as the Blizzard/Minimap toggles above) — and lives here rather than
        -- on the per-mode Frame page.
        --
        -- ☠ AT PAGE SCOPE, like the two makeBliz helpers: the classic box and every
        -- pane instance must drive the same refresh, and it closes over nothing
        -- group-specific.
        local function refreshPixelPerfect()
            -- Re-apply header sizing + refresh the live frames (UpdateAllFrames auto-
            -- routes party vs raid by the real in-world context) plus any test frames.
            if DF.headersInitialized and DF.ApplyHeaderSettings then DF:ApplyHeaderSettings() end
            if DF.UpdateAllFrames then DF:UpdateAllFrames() end
            if (DF.testMode or DF.raidTestMode) and DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
        end

        -- Verbatim, taking the group and parent it should build into -- the tick,
        -- its blurb, the live scale hint, the update-rate dropdown and its blurb.
        --
        -- ☠ THE SCALE HINT'S refreshContent SURVIVES THE MOVE, and it has to:
        -- the pane's reflow calls the group's RefreshChildStates, which walks
        -- groupChildren calling refreshContent on every shown child (DandersUI
        -- Sections.lua). So the hint re-computes inside an open panel exactly
        -- as it did inline on the page.
        local function BuildRenderingGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateCheckbox(parent, L["Pixel-Perfect Scaling"],
                nil, nil, refreshPixelPerfect,
                makeBlizGet("pixelPerfect"), makeBlizSet("pixelPerfect"), "pixelPerfect"), 30)
            -- Label slots below are sized for the WRAPPED text plus a gap. Labels are
            -- variable-height widgets (GUI.RowHeight only governs fixed ones), so the
            -- slot is whatever is passed here — too small and the next widget's label
            -- sits on the last line of this one.
            group:AddWidget(GUI:CreateLabel(parent,
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
                local scaleHint = GUI:CreateLabel(parent, computeScaleHint(), 250)
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
                group:AddWidget(scaleHint, 72)
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
            group:AddWidget(GUI:CreateDropdown(parent, L["Aura Duration Update Rate"],
                auraDurRateValues, DF:GetGlobalDB(), "auraDurationUpdateInterval", function()
                    if DF.InvalidateAuraDurationUpdateInterval then DF:InvalidateAuraDurationUpdateInterval() end
                    if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
                    if DF.UpdateAllFrames then DF:UpdateAllFrames() end
                    if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end), 55)
            group:AddWidget(GUI:CreateLabel(parent,
                L["How often aura countdown text refreshes. Smooth updates ten times a second, Performance once a second. Normal keeps the standard rate."],
                250), 52)
        end

        if classicLayout then
            -- ===== RENDERING GROUP (Column 1) =====
            local renderingGroup = GUI:CreateSettingsGroup(self.child, 280)
            renderingGroup:AddWidget(GUI:CreateHeader(self.child, L["Rendering"]), 40)
            BuildRenderingGroup({
                group = renderingGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(renderingGroup, nil, 1)
        else
            -- One word, and only for the two states worth a word: the update rate
            -- when it is not the shipped NORMAL. Pixel-Perfect Scaling is not in
            -- here: it is read party-canonical from another table, and a yes/no
            -- has no word to spend anyway.
            local function RenderingSummary(d)
                if not d then return "" end
                local parts = {}
                local rate = d.auraDurationUpdateInterval
                if rate == "SMOOTH" then parts[#parts + 1] = L["Smooth"]
                elseif rate == "PERFORMANCE" then parts[#parts + 1] = L["Performance"]
                end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ THE ACCOUNT-WIDE TABLE, NOT THE PAGE'S. A card's summary is handed
            -- the per-mode db; the update rate lives in DF:GetGlobalDB(), so the
            -- summary reads that and ignores what it was handed.
            --
            -- Column 2 opens here. Two independent settings, so no header tick.
            -- Render quality is how the frames LOOK, so it is pinnable.
            local band = OpenSection(L["Rendering"], "general_rendering", 2,
                function() return RenderingSummary(DF:GetGlobalDB()) end, nil, nil, BuildRenderingGroup)
            BuildRenderingGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== SETTINGS PANEL APPEARANCE (a 280 box in classic, a card) =====
        -- Controls the look of this settings panel itself — does NOT affect
        -- in-game frame text (use Health Text / Name Text pages for those).
        local function BuildPanelAppearanceGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateFontDropdown(parent, L["Settings Font"], DF.db, "settingsFont", function()
                if GUI.RefreshSettingsFont then GUI:RefreshSettingsFont() end
            end), 55)
            group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Settings Font Outline"], DF.db, "settingsFontOutline", function()
                if GUI.RefreshSettingsFont then GUI:RefreshSettingsFont() end
            end), 55)
            group:AddWidget(GUI:CreateLabel(parent,
                L["Font used for this settings panel. Does not affect in-game frame text — use the Text Designer for those."],
                260), 60)

            -- Classic-layout fallback for the settings redesign. Account-level and
            -- stored at the ROOT of the SavedVariable, so it takes the get/set form of
            -- the factory rather than a (dbTable, key) pair — same shape the Blizzard /
            -- minimap toggles above use for their non-db storage. No overrideKey: this
            -- is not a profile setting, so it has no auto-profile override to indicate.
            --
            -- ⚠ TEMPORARY. Remove this control (and DF:IsClassicSettingsLayout) once the
            -- popout redesign is finished.
            --
            -- ☠☠ THE ESCAPE HATCH CAN LIVE INSIDE A PINNED PANEL, AND THE FLIP
            -- TAKES EVERY PANEL DOWN ITSELF -- BEFORE the rebuild, which is the
            -- whole point. In Modern this tick sits in the Settings Panel
            -- Appearance card, which is pinnable, so the click that turns classic
            -- ON can happen with a panel standing open that the shell's own
            -- source-death tick leaves alone.
            --
            -- ⚠ GUI:CreatePopoutPageTools DOES CLOSE PANELS ON A CLASSIC BUILD --
            -- its prologue runs above the classic early return, deliberately -- so
            -- this line is no longer the ONLY thing that would close them. It is
            -- kept because it is the only thing that closes them AT THE RIGHT
            -- MOMENT: DoBuild retires a page's children BEFORE it calls the
            -- builder, so the helper's close lands after the row the panel is
            -- wired to is already in the trash. Closing here, ahead of the
            -- rebuild, closes them while their rows are still alive. (It also
            -- covers the path where RefreshCurrentPage returns early and no
            -- builder runs at all.) Both are guarded no-ops the second time.
            --
            -- ⚠ AND THE REBUILD STAYS SYNCHRONOUS, unlike the Frame page's Raid
            -- Layout Mode toggle. That one is deferred because the tick is ON THE
            -- ROW and the kit calls row.Refresh() after the write -- on a frame the
            -- rebuild has just retired. This tick is an ordinary checkbox INSIDE
            -- the pane: the factory's OnClick does the write, this callback, then
            -- `parent.RefreshStates` (the pane holder has none) and DF:UpdateAll,
            -- so there is no row refresh to land on a dead frame and nothing to
            -- gain from a frame's delay.
            --
            -- ⚠ Unconditional, not popout-only: in classic there is no open panel
            -- and CloseAllPopoutRows is a guarded no-op, so one builder still
            -- serves both layouts. It also takes down any panel PINNED out of the
            -- layout being left, which is right -- those belong to the old shape.
            local classicCheck = group:AddWidget(GUI:CreateCheckbox(
                parent, L["Use classic settings layout"],
                nil, nil,
                function()
                    -- The one shared flip -- GUI:FlipSettingsLayout (GUI/Panel.lua)
                    -- runs the whole sequence the notes above describe, in the
                    -- order they demand (panels first, then every page's build
                    -- cache, then the page on screen, then the title-bar glyph's
                    -- tint). The factory's set has already written the field, so
                    -- the value passed here is a restated no-op write and the
                    -- sequence is the whole point.
                    GUI:FlipSettingsLayout(DF:IsClassicSettingsLayout())
                end,
                function() return DF:IsClassicSettingsLayout() end,
                function(val) DF:SetClassicSettingsLayout(val) end
            ), 30)
            classicCheck.tooltip = L["Show settings groups in the classic inline layout instead of the popout rows. Applies to the whole account, and can also be switched from the button in the window's title bar."]
        end

        if classicLayout then
            -- ===== SETTINGS PANEL APPEARANCE GROUP (Column 2, Top) =====
            local panelAppearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
            panelAppearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings Panel Appearance"]), 40)
            BuildPanelAppearanceGroup({
                group = panelAppearanceGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(panelAppearanceGroup, nil, 2)
        else
            -- ⚠ THE FONT NAME IS UNCONDITIONAL, and it is the whole summary: the
            -- one applied, visible state here, since the user is looking at the
            -- font while they read it. The NAME comes from DF:GetFontNameFromPath,
            -- the resolver CreateFontDropdown prints on its own button. The
            -- classic-layout switch has no word, so it is not in here.
            local function PanelAppearanceSummary(d)
                if not d then return "" end
                local name = DF.GetFontNameFromPath and DF:GetFontNameFromPath(d.settingsFont)
                if type(name) == "string" and name ~= "" then return name end
                return ""
            end

            -- ☠ THE PROFILE ROOT, NOT THE PAGE'S TABLE. A card's summary is handed
            -- the per-mode db; settingsFont lives at DF.db itself, so the summary
            -- reads the root and ignores what it was handed.
            --
            -- How the settings window LOOKS, so it is pinnable. ⚠ The classic
            -- layout switch rides in here, in a pinned copy too: flipping it runs
            -- GUI:FlipSettingsLayout, which closes every panel first.
            local band = OpenSection(L["Settings Panel Appearance"], "general_panelappearance", 2,
                function() return PanelAppearanceSummary(DF.db) end, nil, nil, BuildPanelAppearanceGroup)
            BuildPanelAppearanceGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== LANGUAGE (Column 2 in classic; the last card in Modern) ========
        -- Modern builds its card at the foot of the page -- see MINIMAP AND
        -- LANGUAGE, AS CARDS.
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
        -- The reload prompt, under a name at page scope: the classic dropdown and
        -- the card's dropdown must run the SAME callback, and a second copy of
        -- a four-branch popup is the kind of duplication that drifts a button
        -- caption. The body is the one that was inline here, unchanged.
        local function PromptLanguageReload()
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
        end

        if classicLayout then
            local languageGroup = GUI:CreateSettingsGroup(self.child, 280)
            languageGroup:AddWidget(GUI:CreateHeader(self.child, L["Language"]), 40)
            -- Language override lives on the per-character SavedVariable so
            -- locale files can read it at file-load time (before DF.db exists).
            languageGroup:AddWidget(GUI:CreateDropdown(self.child, L["Addon Language"], languageValues, DandersFramesCharDB, "languageOverride", PromptLanguageReload), 55)
            languageGroup:AddWidget(GUI:CreateLabel(self.child,
                L["Override the addon's display language. Auto follows your WoW client language. Translations are community-contributed and may be incomplete."],
                260), 60)
            Add(languageGroup, nil, 2)
        end

        -- ===== NOTIFICATIONS (a 280 box in classic, a card in Modern) =======
        -- Verbatim, including the two empty-bodied callbacks: neither setting has
        -- anything to re-render now (one is read by the version check, the other
        -- at next login), and the comments saying so are the reason nobody adds a
        -- refresh call to them.
        local function BuildNotificationsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateCheckbox(parent, L["Notify me when a newer version is available"],
                DF:GetGlobalDB(), "notifyOutdated", function()
                    -- Setting applies immediately; no extra callback needed.
                end), 30)
            local loginMsgCheck = group:AddWidget(GUI:CreateCheckbox(parent, L["Show the login message"],
                DF:GetGlobalDB(), "showLoginMessage", function()
                    -- Read once at login; nothing to re-render now.
                end), 30)
            loginMsgCheck.tooltip = L["The one-line greeting printed to chat when you log in. Takes effect at your next login."]
        end

        if classicLayout then
            -- ===== NOTIFICATIONS GROUP (Column 2, Bottom) =====
            local notificationsGroup = GUI:CreateSettingsGroup(self.child, 280)
            notificationsGroup:AddWidget(GUI:CreateHeader(self.child, L["Notifications"]), 40)
            BuildNotificationsGroup({
                group = notificationsGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(notificationsGroup, nil, 2)
        else
            -- ☠ NO SUMMARY. Two yes/nos, and neither has a word the locale ships
            -- that could stand in for it. Two independent switches, so no header
            -- tick; behaviour, so no pin. The last card down column 1.
            local band = OpenSection(L["Notifications"], "general_notifications", 1, nil)
            BuildNotificationsGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== MINIMAP AND LANGUAGE, AS CARDS (Modern only) =================
        -- ☠ BUILT HERE, AT THE FOOT, NOT BESIDE THEIR CLASSIC BOXES. A card goes
        -- into its column the moment CloseSection runs, so the order cards are
        -- built in IS the order they stack in: these two follow Rendering and
        -- Settings Panel Appearance down column 2, and on a narrow window the
        -- page folds to the five multi-setting cards first and these two last.
        --
        -- ☠ ONE SETTING EACH, SO EACH CARD HOLDS ITS CONTROL AND NO HEADER TICK
        -- -- the same call classic makes, on the same storage, so the search
        -- entry is the one classic registers. Neither decides how anything
        -- looks, so neither is pinnable.
        if not classicLayout then
            -- The minimap button is a single global UI element (no mode): read
            -- party-canonical, written to both modes, exactly as classic's tick.
            local minimapCard = OpenSection(L["Minimap"], "general_minimap", 2, nil)
            minimapCard:AddWidget(GUI:CreateCheckbox(self.child, L["Show Minimap Button"], nil, nil, function()
                DF:UpdateMinimapButton()
            end, makeBlizGet("showMinimapButton"), makeBlizSet("showMinimapButton"), "showMinimapButton"), 30)
            CloseSection(minimapCard)

            -- Language override lives on the per-character SavedVariable so
            -- locale files can read it at file-load time (before DF.db exists).
            -- The blurb is measured, not pinned: at the card's width it wraps to
            -- fewer lines than at classic's 260.
            local languageCard = OpenSection(L["Language"], "general_language", 2, nil)
            languageCard:AddWidget(GUI:CreateDropdown(self.child, L["Addon Language"], languageValues, DandersFramesCharDB, "languageOverride", PromptLanguageReload), 55)
            languageCard:AddWidget(GUI:CreateLabel(self.child,
                L["Override the addon's display language. Auto follows your WoW client language. Translations are community-contributed and may be incomplete."],
                GUI:GroupInnerWidth(languageCard)))
            CloseSection(languageCard)
        end
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
        -- ⚠ The two grouped-raid sliders are NOT re-labelled on a direction change:
        -- "Groups Before Wrap" and "Wrap Spacing" name the wrap, not the axis, so
        -- they do not swap. Only the flat grid's slider still names an axis.
        local function UpdateDynamicLabels()
            if playersPerRowSlider and playersPerRowSlider.label then
                playersPerRowSlider.label:SetText(db.growDirection == "VERTICAL" and L["Players Per Column"] or L["Players Per Row"])
            end
        end
        
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
        
        -- CLASSIC: column 1 is the layout chain -- size, direction, raid mode,
        -- and whichever group detail that mode implies. Column 2 keeps
        -- Appearance at the top, where styling sits on every other page.
        --
        -- Six boxes against three is not the imbalance it looks: FIVE of
        -- the left column's boxes are raid-only, so in party mode the page
        -- is Frame Size + Layout Direction against Appearance + Permanent
        -- Mover. Permanent Mover is also by far the biggest box here, which
        -- carries column 2 in raid.
        --
        -- MODERN is the Debuff Bar's collapsible-card design, one card per
        -- group: two settings per row inside a card wide enough, dim captions,
        -- the value summary in a shut card's corner, Expand All / Collapse All at
        -- the top. Every card now behaves the same way -- the old page had three
        -- (plated rows with a strip, rows behind a panel, rows with hoisted
        -- controls on the plate).
        --
        --   column 1   "Layout"      Frame Size, Layout Direction, then the raid
        --                            cards (Raid Layout Mode, Group Layout
        --                            Settings, Group Visibility, Group Display
        --                            Order, Flat Grid Settings), each hidden
        --                            outside the mode it belongs to
        --              "Movement"    Permanent Mover (tick: permanentMover)
        --   column 2   "Appearance"  Border (tick: frameShowBorder), Border Shadow
        --                            (tick: frameBorderShadowEnabled, greys with
        --                            Show Border), Frame Fade (tick:
        --                            frameFadeEnabled)
        --
        -- Pins on the cards that decide how the frames LOOK: Frame Size, the
        -- three Appearance cards, Group Layout Settings and Flat Grid Settings.
        -- Layout Direction is not, because its dropdown rebuilds the page.
        local classicLayout = DF:IsClassicSettingsLayout()

        -- The shared page-scope machinery. Its PROLOGUE closes any panel a previous
        -- build left standing and retires that build's holders, and it carries the
        -- section helper the card pages build with. nil in classic, which is what
        -- every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE SECTION: the Debuff Bar's helper (tools.OpenSection) and its two
        -- opt-ins, which every card here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ===== APPEARANCE: THE CLASSIC CONTAINER ============================
        -- CLASSIC -- exactly what it has always been: a 280 box, in column 2,
        -- added at its own place in the flow further down, holding the border,
        -- the shadow block and nothing else. Modern builds no container: its
        -- three Appearance groups are cards of their own.
        local appearanceGroup
        if classicLayout then
            appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        end

        -- ===== FRAME SIZE (a 280 box in classic, the first Layout card) =====
        -- Verbatim, taking the group and parent it should build into -- same
        -- factories, same L keys, same db keys, same callbacks, same slot
        -- heights, same hideOn. Guarded by test_frame_page_builders.lua, which
        -- reads this body out of the source and checks it against the inventory
        -- it had inline.
        local function BuildFrameSizeGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateSlider(parent, L["Frame Width"], 60, 300, 1, db, "frameWidth", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Frame Height"], 20, 300, 1, db, "frameHeight", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Frame Padding"], 0, 10, 1, db, "framePadding", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Frame Scale"], 0.5, 2.0, 0.05, db, "frameScale", function() DF:UpdateContainerPosition() DF:UpdateRaidContainerPosition() UpdateFrames() end, function() DF:LightweightUpdateFrameScale() end, true), 55)
            local frameSpacingSlider = group:AddWidget(GUI:CreateSlider(parent, L["Frame Spacing"], -5, 50, 1, db, "frameSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSpacing() end, true), 55)
            frameSpacingSlider.hideOn = function() return GUI.SelectedMode == "raid" and not db.raidUseGroups end
        end


        if classicLayout then
            local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
            sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Size"]), 40)
            BuildFrameSizeGroup({
                group = sizeGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(sizeGroup, nil, 1)
        else
            -- The summary, per the convention the border cards set: at most four
            -- items, a fixed order, "\194\183" between them, WORDS localised and
            -- numbers raw. The SIZE is unconditional -- it is the question the
            -- group exists to answer. The other three only when changed.
            --
            -- ☠ "138x59", NOT the multiplication sign: the settings panel draws in
            -- the user's Settings Font, which carries Latin, digits and
            -- punctuation.
            local function FrameSizeSummary(d)
                if not d then return "" end
                local D = DF.Defaults
                local parts = {}
                local w, h = tonumber(d.frameWidth), tonumber(d.frameHeight)
                if w and h then
                    parts[#parts + 1] = format("%dx%d", math.floor(w), math.floor(h))
                end
                -- "Not the shipped default" via the defaults engine rather than a
                -- literal per key: the defaults live in Config.lua and a number
                -- copied here would be a second copy nothing keeps in step.
                local function changed(key) return D and D:IsModified(d, key) end
                local sc = tonumber(d.frameScale)
                if sc and changed("frameScale") then
                    parts[#parts + 1] = format("%s %.2f", L["Scale"], sc)
                end
                local pad = tonumber(d.framePadding)
                if pad and changed("framePadding") then
                    parts[#parts + 1] = format("%s %d", L["Padding"], math.floor(pad))
                end
                local sp = tonumber(d.frameSpacing)
                if sp and changed("frameSpacing") then
                    parts[#parts + 1] = format("%s %d", L["Spacing"], math.floor(sp))
                end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Buff Bar's placement and its reasons: they act on cards in both
            -- columns, and "both" carries them through the one-column fold intact.
            Add(tools.SectionControls(self.child), 24, "both")
            -- The category header the layout cards sit under.
            Add(GUI:CreateHeader(self.child, L["Layout"]), 40, 1)
            -- No tick: a frame has a size either way. How big a frame is is how
            -- it LOOKS, so it is pinnable.
            local band = OpenSection(L["Frame Size"], "frame_size", 1, FrameSizeSummary, nil, nil, BuildFrameSizeGroup)
            BuildFrameSizeGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== APPEARANCE GROUP (Column 2, or the full-width band) =====
        -- The classic container is built above -- see the note there. Modern
        -- draws the same "Appearance" word as the category header over its three
        -- cards instead (see the border arm below).
        if classicLayout then
            appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        end
        -- Canonical border controls via the unified helper. Replaces the
        -- previous hand-rolled Show / Color / Style / Texture / Size block.
        -- classColor + roleColor are now first-class helper include flags (no
        -- bespoke "Use Class Color" extra needed). (Pixel-Perfect Scaling moved
        -- to General > Settings > Rendering — it's a global, mode-agnostic flag.)
        --
        -- Border and Border Shadow are TWO builders, each taking the group and
        -- parent it should build into, because Modern mounts them as two cards.
        -- Classic mounts them back-to-back into the one Appearance box, which is
        -- the same panel, in the same order, as the single CreateBorderControls
        -- call they replaced.
        --
        -- ⚠ shadowDisableWhen is not decoration. In the single call the shadow
        -- rows greyed with Show Border because CreateBorderControls' own
        -- composition loop reached them; split out, the shadow builder is never
        -- inside that loop, so the same predicate has to be handed to it.
        local function BuildBorderGroup(tools2)
            GUI:CreateBorderControls(tools2.group, db, "frame", {
                parent       = tools2.parent,
                include      = {
                    -- Frame Border is the outer chrome of the unit. It's a
                    -- structural element, not an alert surface, so animations
                    -- don't fit the design.
                    inset = true, offset = true, blendMode = true,
                    gradient = true,
                    classColor = true, roleColor = true,
                    alpha = true,
                },
                fullUpdate   = function() UpdateFrames() DF:LightweightUpdateBorder() end,
                lightUpdate  = function() DF:LightweightUpdateBorder() end,
                lightColors  = function() DF:LightweightUpdateBorderColor() end,
                refreshStates = tools2.refreshStates,
                sizeMin = 1, sizeMax = 16, sizeStep = 1,
                noShowToggle = tools2.hoistToggles or nil,
            })
        end
        local function BuildBorderShadowGroup(tools2)
            GUI:CreateBorderShadowControls(tools2.group, db, "frame", {
                parent       = tools2.parent,
                -- No lightColors: the shadow colour picker commits through
                -- fullUpdate, exactly as it did inside the single call.
                fullUpdate   = function() UpdateFrames() DF:LightweightUpdateBorder() end,
                lightUpdate  = function() DF:LightweightUpdateBorder() end,
                refreshStates = tools2.refreshStates,
                hideWhen     = tools2.shadowHideWhen,
                disableWhen  = tools2.shadowDisableWhen,
                noEnableToggle = tools2.hoistToggles or nil,
            })
        end
        -- Show Border off greys the shadow block, in BOTH layouts. In the single
        -- call it fell out of CreateBorderControls' own composition loop; split
        -- out (and split again into two cards) the predicate has to be handed
        -- over explicitly. One definition, both branches.
        local function BorderOff() return db.frameShowBorder == false end


        if classicLayout then
            local borderTools = {
                group  = appearanceGroup,
                parent = self.child,
                -- A state pass, not a rebuild: every border control carries its
                -- gate as hideOn/disableOn (GUI:CreateBorderControls).
                refreshStates = function() GUI.RelayoutCurrentPage() end,
                shadowDisableWhen = BorderOff,
            }
            BuildBorderGroup(borderTools)
            BuildBorderShadowGroup(borderTools)
        else
            -- ===== THE SAME TWO GROUPS, AS TWO CARDS ========================
            -- The group's own apply: what its widgets' callbacks already do, named
            -- once so both header ticks run the same work.
            local function ApplyBorder()
                UpdateFrames()
                DF:LightweightUpdateBorder()
            end

            -- ☠ NOT GUI:RefreshCurrentPage. A rebuild retires every widget on the
            -- page, the header tick being clicked included. What a tick has to buy
            -- is the hideOn/disableOn passes (Show Border greys the shadow card's
            -- header and body) and a repaint of any pinned panel.
            local function OnBorderToggle()
                ApplyBorder()
                self:RefreshStates()
                tools.ReflowMounted()
            end

            -- The summaries. At most four items, a fixed order, "\194\183" between
            -- them, labels or units only where a bare number would be ambiguous,
            -- WORDS localised and numbers raw, every read guarded.
            local function BorderSummary(d)
                if not d then return "" end
                local parts = {}
                local size = tonumber(d.frameBorderSize)
                if size then
                    parts[#parts + 1] = format("%dpx", math.floor(size))
                end
                local style = d.frameBorderStyle
                parts[#parts + 1] = (style == "GRADIENT" and L["Gradient"])
                                 or (style == "TEXTURE" and L["Texture"])
                                 or L["Solid"]
                -- STATIC is the default and says nothing; the other two are the
                -- whole reason a border may not be the colour beneath it.
                local src = d.frameBorderColorSource
                if src == "CLASS" then parts[#parts + 1] = L["Class"]
                elseif src == "ROLE" then parts[#parts + 1] = L["Role"] end
                -- ☠ THE WORD, NOT "\206\177" (U+03B1). The settings panel draws in
                -- the user's Settings Font, and the shipped default carries no
                -- Greek. Only when the alpha is actually doing something.
                local c = d.frameBorderColor
                local a = type(c) == "table" and tonumber(c.a) or nil
                if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
                return table.concat(parts, " \194\183 ")
            end

            local function ShadowSummary(d)
                if not d then return "" end
                local parts = {}
                local size = tonumber(d.frameBorderShadowSize)
                if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
                local ox = tonumber(d.frameBorderShadowOffsetX) or 0
                local oy = tonumber(d.frameBorderShadowOffsetY) or 0
                if ox ~= 0 or oy ~= 0 then
                    parts[#parts + 1] = format("%d, %d", math.floor(ox), math.floor(oy))
                end
                return table.concat(parts, " \194\183 ")
            end

            -- Show Border off greys the shadow card: its header (the dim gate and
            -- the tick's own gate) and its body (shadowDisableWhen, below).
            local function ShadowGatedOff(d) return (d or db).frameShowBorder == false end

            -- ☠ THE SHADOW PIN NEEDS THE GATE HANDED OVER. A pinned panel mounts
            -- the section's builder with the four standard fields only, and the
            -- shadow builder takes Show Border's grey through shadowDisableWhen --
            -- so the pin mounts it through this one wrapper, the same builder with
            -- the same gate the card's body gets.
            local function BuildBorderShadowPinned(tools2)
                tools2.shadowDisableWhen = BorderOff
                BuildBorderShadowGroup(tools2)
            end

            -- Column 2 opens here, with the category header its three cards sit
            -- under.
            Add(GUI:CreateHeader(self.child, L["Appearance"]), 40, 2)

            -- ☠ SHOW BORDER IS THE HEADER'S TICK, so the toolkit is told not to
            -- build its own (hoistToggles -> noShowToggle); showKey is still read,
            -- so the rest of the border greys exactly as before. How the frame's
            -- edge LOOKS, so it is pinnable.
            local borderBand = OpenSection(L["Border"], "frame_border", 2, BorderSummary, nil, nil, BuildBorderGroup, {
                db = db, key = "frameShowBorder", label = L["Show Border"],
                isOn = function(d) return d.frameShowBorder ~= false end,
                onChanged = OnBorderToggle,
            })
            BuildBorderGroup({
                group = borderBand, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggles = true,
            })
            CloseSection(borderBand)

            -- ☠ THE SHADOW'S ENABLE IS ITS HEADER'S TICK (hoistToggles ->
            -- noEnableToggle), and the whole card greys while Show Border is off,
            -- the tick included -- as the in-body block always did. Pinnable.
            local shadowBand = OpenSection(L["Border Shadow"], "frame_bordershadow", 2, ShadowSummary, ShadowGatedOff, nil,
                BuildBorderShadowPinned, {
                    db = db, key = "frameBorderShadowEnabled", label = L["Border Shadow"],
                    disableOn = ShadowGatedOff,
                    onChanged = OnBorderToggle,
                })
            BuildBorderShadowGroup({
                group = shadowBand, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                shadowDisableWhen = BorderOff,
                hoistToggles = true,
            })
            CloseSection(shadowBand)
        end
        -- Classic only: Modern has no Appearance container -- its three cards
        -- were each added as they were built.
        if classicLayout then Add(appearanceGroup, nil, 2) end

        -- ===== FRAME FADE (Column 2 box in classic, the third Appearance card) =
        -- Whole-frame base opacity, multiplied with the range / health fades
        -- (DF:GetFrameBaseAlpha, ElementAppearance). One global slider, or -- with the
        -- split on -- an out-of-combat and an in-combat value, plus a hover option that
        -- shows the in-combat value while the mouse is on a frame out of combat.
        --
        -- ☠ THE TICK IS frameFadeEnabled, AND IT IS NOT frameFadeSplitCombat.
        -- The group went a whole release without one because it had no boolean
        -- meaning "am I doing anything at all" -- and the candidate that looked
        -- like one was wrong twice over: the split is a MODE rather than an
        -- enable (both states fade), and it HIDES the global slider, so a tick
        -- that switched it off would grey the one control the group exists for.
        -- So the missing boolean was ADDED (Config.lua, defaulting true) rather
        -- than borrowed, and the engine reads it before anything else it fades on
        -- (DF:GetFrameBaseAlpha). Off means alpha 1, not alpha 0.1.
        local function RefreshFrameFade()
            if DF.InvalidateHealthFadeCurve then DF:InvalidateHealthFadeCurve() end
            -- Pets re-apply their fade only on a range-cache miss; flush it so the
            -- next tick picks up the new base instead of waiting for a range change.
            if DF.ClearRangeCache then DF:ClearRangeCache() end
            DF:RefreshAllVisibleFrames()
            if DF.UpdateAllFrameAppearances then DF:UpdateAllFrameAppearances() end
        end

        -- The group's seven controls, verbatim, taking the group and parent they
        -- should build into. Same factories, same L keys, same db keys, same
        -- callbacks, same slot heights, same hideOn/disableOn -- the only thing
        -- the move changed is where `group`, `parent` and the state refresh come
        -- from. Guarded by test_frame_page_builders.lua, which reads this body
        -- out of the source and checks it against the inventory it had inline.
        local function BuildFrameFadeGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the card's HEADER carries this tick. Still built in
            -- classic, where it is the group's only on/off control.
            if not tools2.hoistToggle then
                local ffEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Frame Fade"], db, "frameFadeEnabled", RefreshFrameFade), 30)
                ffEnable.keepEnabled = true
            end
            -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER, as it does on every other
            -- header-tick group on this page: classic greys its own children off
            -- this, the card's body has to do the same, and one builder serving
            -- both is what stops the two drifting.
            group.disableChildrenOn = function(d) return not d.frameFadeEnabled end

            local ffGlobal = group:AddWidget(GUI:CreateSlider(parent, L["Global Frame Fade"], 0.1, 1.0, 0.05, db, "frameFadeAlpha", nil, RefreshFrameFade, true), 55)
            ffGlobal.hideOn = function(d) return d.frameFadeSplitCombat end
            ffGlobal.tooltip = L["Opacity of every unit frame. Multiplies with the out-of-range and health fades."]
            group:AddWidget(GUI:CreateCheckbox(parent, L["Separate Combat Fade"], db, "frameFadeSplitCombat", function()
                tools2.refreshStates()
                RefreshFrameFade()
            end), 30)
            local ffOOC = group:AddWidget(GUI:CreateSlider(parent, L["Out of Combat Frame Fade"], 0.1, 1.0, 0.05, db, "frameFadeAlphaOutOfCombat", nil, RefreshFrameFade, true), 55)
            ffOOC.hideOn = function(d) return not d.frameFadeSplitCombat end
            ffOOC.tooltip = L["Frame opacity while you are out of combat. The preview shows this value while you configure it."]
            local ffCombat = group:AddWidget(GUI:CreateSlider(parent, L["In Combat Frame Fade"], 0.1, 1.0, 0.05, db, "frameFadeAlphaInCombat", nil, RefreshFrameFade, true), 55)
            ffCombat.hideOn = function(d) return not d.frameFadeSplitCombat end
            local ffInstance = group:AddWidget(GUI:CreateCheckbox(parent, L["Use In-Combat Fade In Instances"], db, "frameFadeInstanceUsesCombat", RefreshFrameFade), 30)
            ffInstance.disableOn = function(d) return not d.frameFadeSplitCombat end
            ffInstance.tooltip = L["Inside dungeons, raids, arenas and battlegrounds the frames hold the in-combat opacity the whole visit — no fading out between pulls."]
            local ffHover = group:AddWidget(GUI:CreateCheckbox(parent, L["Show In-Combat Fade When Hovering"], db, "frameFadeHoverUsesCombat", RefreshFrameFade), 30)
            ffHover.disableOn = function(d) return not d.frameFadeSplitCombat end
            ffHover.tooltip = L["Out of combat, a frame under the mouse uses the in-combat opacity so you can still read and interact with it."]
            local ffHoverScope = group:AddWidget(GUI:CreateDropdown(parent, L["Hover Applies To"], {
                ALL   = L["All Frames"],
                FRAME = L["Hovered Frame Only"],
            }, db, "frameFadeHoverScope", RefreshFrameFade), 55)
            ffHoverScope.disableOn = function(d) return not d.frameFadeSplitCombat or not d.frameFadeHoverUsesCombat end
            ffHoverScope.tooltip = L["All Frames lifts every unit frame while the mouse is on any of them, so the whole group is readable and clickable."]
        end

        if classicLayout then
            local frameFadeGroup = GUI:CreateSettingsGroup(self.child, 280)
            frameFadeGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Fade"]), 40)
            BuildFrameFadeGroup({
                group = frameFadeGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(frameFadeGroup, nil, 2)
        else
            -- The summary, per the same convention the border cards follow: at
            -- most four items, a fixed order, "\194\183" between them, WORDS
            -- localised and numbers raw, and every opacity carries the word that
            -- says WHICH opacity it is. Two shapes, because the group has two: one
            -- value when the split is off, the out-of-combat value plus the
            -- in-combat one when it is on.
            local function FrameFadeSummary(d)
                if not d then return "" end
                local parts = {}
                local base = d.frameFadeSplitCombat and d.frameFadeAlphaOutOfCombat
                                                     or d.frameFadeAlpha
                base = tonumber(base)
                if base then parts[#parts + 1] = format("%s %.2f", L["Alpha"], base) end
                if d.frameFadeSplitCombat then
                    local inc = tonumber(d.frameFadeAlphaInCombat)
                    if inc then parts[#parts + 1] = format("%s %.2f", L["Combat"], inc) end
                end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ ENABLE FRAME FADE IS THE HEADER'S TICK, so the builder is told not
            -- to build its own (hoistToggle). The commit is what the in-body
            -- checkbox ran plus the state pass that greys the seven behind it and
            -- a repaint of a pinned panel -- never a page rebuild. How much of the
            -- frame you can see is how it LOOKS, so it is pinnable.
            local band = OpenSection(L["Frame Fade"], "frame_fade", 2, FrameFadeSummary, nil, nil, BuildFrameFadeGroup, {
                db = db, key = "frameFadeEnabled", label = L["Enable Frame Fade"],
                onChanged = function()
                    RefreshFrameFade()
                    self:RefreshStates()
                    tools.ReflowMounted()
                end,
            })
            BuildFrameFadeGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end


        -- ===== LAYOUT DIRECTION (a 280 box in classic, a Layout card) =======
        -- Three dropdowns and never more than two of them visible: the two
        -- Growth Direction variants are mutually exclusive, and Frames Grow
        -- From is party-only.

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

        -- ☠☠ THE TWO DIALECTS OF ONE KEY, AND THE ONLY PLACE THEY ARE SPELLED.
        -- growDirection means the same stored value in both modes and the WORD
        -- for it inverts: on party (and flat raid) the repeating unit is a line
        -- of frames, so HORIZONTAL reads "Rows"; on grouped raid the repeating
        -- unit is a GROUP, so the same value reads "Columns". Two maps, one key,
        -- deliberately -- see the ☠☠ block below the dropdowns for what has
        -- already been broken by trying to unify them.
        --
        -- ⚠ AT PAGE SCOPE, SO THERE IS ONE COPY. A map whose whole hazard is that
        -- it has an inverse is written out once, so a second reader cannot drift
        -- from it.
        -- ⚠ Built on CALL, never at file scope: a table baked from L at load
        -- freezes on enUS and never follows a language override.
        local function GrowDirectionOptions(grouped)
            if grouped then
                return { _order = { "HORIZONTAL", "VERTICAL" }, HORIZONTAL = L["Columns"], VERTICAL = L["Rows"] }
            end
            return { _order = { "HORIZONTAL", "VERTICAL" }, HORIZONTAL = L["Rows"], VERTICAL = L["Columns"] }
        end
        -- ...and its explanation, from the same scope and for the same reason:
        -- one setting says one thing about itself, from one place, in whichever
        -- dialect the build is speaking.
        local function GrowDirectionTooltip(grouped)
            if grouped then
                return L["The shape each raid group takes. Columns stack the five players downward and run the groups across; Rows lay them out sideways and stack the groups down.\n\nThe 'Groups Before Wrap' setting below counts the GROUPS, not the players."]
            end
            return L["The shape each line of frames takes. Rows run left to right, Columns run top to bottom."]
        end
        -- Where the run of frames STARTS FROM, party only. A function rather
        -- than a literal for the reason GrowDirectionOptions is one: a map whose
        -- hazard is that it has an inverse is written out once, so a fourth
        -- option cannot reach one reader and miss another.
        -- ⚠ MAIN_START / MAIN_END are baked from db.growDirection at page build,
        -- so the words name the previous orientation's edge until the next
        -- rebuild. Long-standing, and any rebuild puts them right.
        local function GrowthAnchorOptions()
            return { _order = { "START", "CENTER", "END" }, START= MAIN_START, CENTER= L["Center"], END= MAIN_END }
        end

        -- The three dropdowns, verbatim, taking the group and parent they
        -- should build into. Guarded by test_frame_page_builders.lua against
        -- the inventory they had inline.
        local function BuildLayoutDirectionGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local growOptions = GrowDirectionOptions(false)
            local growDrop = group:AddWidget(GUI:CreateDropdown(parent, L["Growth Direction"], growOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
            growDrop.hideOn = function() return GUI.SelectedMode == "raid" and db.raidUseGroups end
            growDrop.tooltip = GrowDirectionTooltip(false)

            -- Grouped raid: same key, inverted labels, because the repeating unit is a group.
            local groupGrowOptions = GrowDirectionOptions(true)
            local groupGrowDrop = group:AddWidget(GUI:CreateDropdown(parent, L["Growth Direction"], groupGrowOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
            groupGrowDrop.hideOn = function() return not (GUI.SelectedMode == "raid" and db.raidUseGroups) end
            groupGrowDrop.tooltip = GrowDirectionTooltip(true)

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

            -- Growth anchor (party only)
            local anchorOptions = GrowthAnchorOptions()
            local anchorDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Frames Grow From"], anchorOptions, db, "growthAnchor", UpdateFrames), 55)
            anchorDropdown.hideOn = function() return GUI.SelectedMode == "raid" end
        end


        if classicLayout then
            local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
            layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout Direction"]), 40)
            BuildLayoutDirectionGroup({
                group = layoutGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(layoutGroup, nil, 1)
        else
            -- Both dropdown values, in the order the card shows them: the shape
            -- of the repeating unit first, then where it starts from. The anchor
            -- half is PARTY ONLY, because the control is.
            --
            -- ☠ THE WORDS ARE DERIVED FROM `d`, NOT FROM THE BUILD-TIME MAIN_ /
            -- CROSS_ LOCALS ABOVE. Those are baked from db.growDirection at build;
            -- a summary is re-read on every refresh.
            local function LayoutDirectionSummary(d)
                if not d then return "" end
                local parts = {}
                local vert    = d.growDirection == "VERTICAL"
                local grouped = GUI.SelectedMode == "raid" and d.raidUseGroups
                -- Grouped raid inverts the pair -- the repeating unit is a GROUP
                -- there, see the ☠☠ note above the dropdowns.
                if grouped then
                    parts[#parts + 1] = vert and L["Rows"] or L["Columns"]
                else
                    parts[#parts + 1] = vert and L["Columns"] or L["Rows"]
                end
                if GUI.SelectedMode ~= "raid" then
                    local a = d.growthAnchor or "START"
                    parts[#parts + 1] = (a == "CENTER" and L["Center"])
                                     or (a == "END" and (vert and L["Bottom"] or L["Right"]))
                                     or (vert and L["Top"] or L["Left"])
                end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ NO PIN, AND IT IS THE REBUILD THAT DECIDES IT. Growth Direction
            -- rebuilds the page (OnGrowthDirectionChanged) and every route into a
            -- page builder closes every open panel, pinned ones included -- so a
            -- pinned copy would shut under the hand that changed it. The card
            -- itself survives the rebuild: its fold is persisted on a stable key.
            local band = OpenSection(L["Layout Direction"], "frame_layoutdirection", 1, LayoutDirectionSummary)
            BuildLayoutDirectionGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== RAID LAYOUT MODE (a 280 box in classic, a raid-only card) =====
        -- Use Group-Based Layout and the blurb that explains the two modes. The
        -- tick is a MODE, not an on/off (flat is a layout too), so it stays in the
        -- card's body.
        --
        -- ☠ raidUseGroups CANNOT be written through a generic reset. Flipping it
        -- has to invert growDirection at the same moment or the raid silently
        -- re-orients (see the ☠☠ note in the apply below), and that compensation
        -- is only correct for a deliberate toggle -- the same rule the grouped
        -- Players Grow From compensation states about itself.

        -- What flipping the toggle costs, less the page rebuild the checkbox's own
        -- callback runs.
        local function ApplyRaidUseGroups()
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
        end

        -- The tick and its blurb. (hoistToggle is never passed today -- the tick is
        -- a mode, so it stays in the body in both layouts.)
        local function BuildRaidModeGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Use Group-Based Layout"], db, "raidUseGroups", function()
                    ApplyRaidUseGroups()
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end), 30)
            end
            group:AddWidget(GUI:CreateLabel(parent, L["Enabled: Players organized by raid groups (1-8).\nDisabled: All players in one flat grid."], 250), 45)
        end

        if classicLayout then
            local raidModeGroup = GUI:CreateSettingsGroup(self.child, 280)
            raidModeGroup:AddWidget(GUI:CreateHeader(self.child, L["Raid Layout Mode"]), 40)
            raidModeGroup.hideOn = function() return GUI.SelectedMode ~= "raid" end
            BuildRaidModeGroup({
                group = raidModeGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(raidModeGroup, nil, 1)
        else
            -- One word, in both states: both are a raid layout, so "Off" would
            -- say the raid was not being laid out at all.
            local function RaidModeSummary(d)
                if not d then return "" end
                return d.raidUseGroups and L["Groups"] or L["Flat"]
            end

            -- ☠ USE GROUP-BASED LAYOUT STAYS IN THE BODY -- NO HEADER TICK. It is
            -- a MODE, not this card's on/off: flat is a layout too, and a shut
            -- card with the tick off would read "Off". In the body it is a page
            -- widget exactly as classic's is, so its callback's synchronous page
            -- rebuild (the flip changes which cards exist and the words every
            -- anchor dropdown offers) retires it the way it retires classic's --
            -- the fold survives (a stable key). Raid only, header and band
            -- together. Behaviour, so no pin.
            local band = OpenSection(L["Raid Layout Mode"], "frame_raidmode", 1, RaidModeSummary, nil,
                function() return GUI.SelectedMode ~= "raid" end)
            BuildRaidModeGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== GROUP LAYOUT SETTINGS (a 280 box in classic, a raid card) =====
        -- Raid + groups only, in both layouts. In classic that is a group-level
        -- hideOn on the box; in Modern it is the SAME predicate on the card's
        -- header and band. This and Flat Grid Settings below read opposite sides
        -- of raidUseGroups, so exactly one of them is ever on the page.
        --
        -- ☠ THE TWO REFRESH COUPLINGS IN HERE ARE NAMED, AND THAT IS WHY THEY
        -- MOVED INSIDE THE BUILDER. UpdateFramesAndGates re-asks the GROUP for a
        -- state pass and UpdatePinMainGroup re-asks the anchor GRID for a repaint;
        -- both used to close over the page-level box. Left out here they would
        -- have gone on refreshing the object the CLASSIC branch built rather than
        -- whichever instance the user is in. Inside the builder `group` and
        -- `groupAnchorGrid` ARE the instance's own, one pair per instance, so a
        -- pinned panel refreshes itself and not the card.
        local function BuildGroupLayoutGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local groupLayoutHint = db.growDirection == "VERTICAL" and L["Players stack horizontally, groups grow top-to-bottom."] or L["Players stack vertically, groups grow left-to-right."]
            -- No fullRow needed: a two-per-row card makes every unbound widget (a
            -- label included) a row of its own, and the classic box is one track.
            group:AddWidget(GUI:CreateLabel(parent, groupLayoutHint, 250), 25)
        
            -- Six controls, four of them directional, and their labels already swap with the
            -- growth direction -- so the tooltips have to swap with it too, or half of them
            -- describe the other orientation. The page rebuilds on a direction change
            -- (OnGrowthDirectionChanged), which is what keeps these in step. isVert and the
            -- MAIN_/CROSS_ edge words are declared once with the anchor options above.
            local groupSpacingSlider = group:AddWidget(GUI:CreateSlider(parent, L["Group Spacing"], -5, 100, 1, db, "raidGroupSpacing", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
            groupSpacingSlider.tooltip = isVert and L["Gap between one group and the next down the same column."]
                or L["Gap between one group and the next along the same row."]

            -- ⚠ "Row Spacing" and "Groups Per Row" are gone, and not for tidiness. With the
            -- Growth Direction dropdown above reading "Columns" in horizontal mode, a box that
            -- then said Row three times was the exact collision Aphoex reported -- "Columns"
            -- names the group's shape, "Row" named the arrangement of groups, both true at
            -- once. These two are the last places the word appeared in the second sense, so
            -- they now describe the WRAP instead, and Row/Column means one thing on this page.
            -- They also stop swapping with the orientation, because wrapping is wrapping.
            rowColSpacingSlider = group:AddWidget(GUI:CreateSlider(parent, L["Wrap Spacing"], -5, 100, 1, db, "raidRowColSpacing", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
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
                if group.RefreshChildStates then group:RefreshChildStates() end
            end
            groupsPerRowSlider = group:AddWidget(GUI:CreateSlider(parent, L["Groups Before Wrap"], 1, 8, 1, db, "raidGroupsPerRow", UpdateFramesAndGates, function()
                DF:LightweightUpdateRaidLayout()
                if group.RefreshChildStates then group:RefreshChildStates() end
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
            local groupAnchorGrid = group:AddWidget(
                -- ⚠ Plain UpdateFramesAndGates: the pin toggle lives inside this widget and
                -- its own Refresh runs on every cell click, so a cell click that changes the
                -- centre-ness needs no GUI:RefreshCurrentPage.
                GUI:CreateAnchorGrid(parent, L["Groups Anchor"], db, "raidGroupAnchor", "raidGroupRowGrowth", UpdateFramesAndGates, {
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
            local centerModeDrop = group:AddWidget(GUI:CreateDropdown(parent, L["Center Mode"], centerModeOptions, db, "raidGroupCenterMode", UpdatePinMainGroup), 55)
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
            local playerAnchorDrop = group:AddWidget(GUI:CreateDropdown(parent, L["Players Grow From"], playerAnchorOptions, db, "raidPlayerAnchor", UpdateFramesAndGates, nil, SetPlayerAnchorKeepingBlock,
                { onRuntimeWrite = PlayerAnchorRuntimeWrite }), 55)
            playerAnchorDrop.tooltip = L["Which end of a group its players fill from. A group with fewer than five players leaves its empty space at the opposite end."]
        
        end

        if classicLayout then
            local groupLayoutGroup = GUI:CreateSettingsGroup(self.child, 280)
            groupLayoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Group Layout Settings"]), 40)
            groupLayoutGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
            BuildGroupLayoutGroup({
                group = groupLayoutGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(groupLayoutGroup, nil, 1)
        else
            -- Wrap first, because it is the number that decides the SHAPE of the
            -- block, then the gap between groups. Center Mode joins only when it
            -- is Fixed. The corner the Groups Anchor picker names is deliberately
            -- absent: it is two keys read through a transpose and a mirror, and a
            -- summary restating that would be a second place for it to be wrong.
            local function GroupLayoutSummary(d)
                if not d then return "" end
                local parts = {}
                parts[#parts + 1] = format("%s %d", L["Wrap"], tonumber(d.raidGroupsPerRow) or 8)
                local gap = tonumber(d.raidGroupSpacing)
                if gap then parts[#parts + 1] = format("%s %d", L["Gap"], math.floor(gap)) end
                if (d.raidGroupCenterMode or "ALL") == "MAIN" then
                    parts[#parts + 1] = L["Fixed"]
                end
                return table.concat(parts, " \194\183 ")
            end

            -- Raid + groups only, header and band together, as the box. How the
            -- groups are arranged is how the raid LOOKS, so it is pinnable -- the
            -- builder's two refresh couplings are its own per instance, so a
            -- pinned copy refreshes itself and not the card.
            local band = OpenSection(L["Group Layout Settings"], "frame_grouplayout", 1, GroupLayoutSummary, nil,
                function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end, BuildGroupLayoutGroup)
            BuildGroupLayoutGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== GROUP VISIBILITY (a 280 box in classic, a raid card) =========
        -- Eight ticks, raid only. The card lays them out two per row when it is
        -- wide enough -- four rows of two is the shape a group picker wants. The
        -- classic box stays one track, as it always was.
        --
        -- ☠ THE TICKS ARE CUSTOM-GET/SET OVER ONE TABLE SETTING. Each stamps a
        -- per-index override key ("raidGroupVisible_3") that the profile does not
        -- ship; the real key is the one table, raidGroupVisible.
        local function ApplyGroupVisibility()
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
        end

        local function BuildGroupVisGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            -- fullRow: a blurb describes the whole card, not the tick beside it.
            -- Inert wherever the interior is one track (the classic box).
            local groupVisHintLabel = group:AddWidget(GUI:CreateLabel(parent, L["Choose which groups to display."], 250), 25)
            groupVisHintLabel.fullRow = true

            if not db.raidGroupVisible then
                db.raidGroupVisible = {[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true}
            end

            for i = 1, 8 do
                local groupIndex = i
                local overrideKey = "raidGroupVisible_" .. i
                group:AddWidget(GUI:CreateCheckbox(parent, L["Group"] .. " " .. i, nil, nil,
                    ApplyGroupVisibility,
                    function() return db.raidGroupVisible[groupIndex] ~= false end,
                    function(val) db.raidGroupVisible[groupIndex] = val end,
                    overrideKey
                ), 25)
            end
        end

        if classicLayout then
            local groupVisGroup = GUI:CreateSettingsGroup(self.child, 280)
            groupVisGroup:AddWidget(GUI:CreateHeader(self.child, L["Group Visibility"]), 40)
            groupVisGroup.hideOn = function() return GUI.SelectedMode ~= "raid" end
            BuildGroupVisGroup({
                group = groupVisGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(groupVisGroup, nil, 1)
        else
            -- How many of the eight are on, and -- while the list is short enough
            -- to be worth reading -- which ones are not.
            local function GroupVisSummary(d)
                if not d then return "" end
                local vis = d.raidGroupVisible
                local shown, hidden = 0, {}
                for i = 1, 8 do
                    if type(vis) ~= "table" or vis[i] ~= false then
                        shown = shown + 1
                    else
                        hidden[#hidden + 1] = i
                    end
                end
                local parts = { format("%d/8", shown) }
                if #hidden > 0 and #hidden <= 3 then
                    parts[#parts + 1] = format("%s %s", L["Hidden"], table.concat(hidden, ", "))
                end
                return table.concat(parts, " \194\183 ")
            end

            -- Raid only, header and band together, as the box. Eight one-word
            -- ticks, which the card lays out two per row when it is wide enough
            -- (the builder's hint is a full row of its own). Which groups show is
            -- behaviour, so no pin.
            local band = OpenSection(L["Group Visibility"], "frame_groupvisibility", 1, GroupVisSummary, nil,
                function() return GUI.SelectedMode ~= "raid" end)
            BuildGroupVisGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== GROUP DISPLAY ORDER (a 280 box in classic, a raid card) =======
        -- ONE track wherever it is built: the box is a blurb, a tick and a 230px
        -- drag list, and the list IS the box -- pairing it with the tick would
        -- give a 25px control a 230px row and still leave the list to fill
        -- whatever was left.
        --
        -- ☠ THE DRAG LIST WORKS WHEREVER IT IS PARENTED, and it is worth saying why
        -- rather than leaving it to be discovered. Every coordinate it uses is
        -- SCREEN space taken live -- container:GetTop()/GetBottom() each frame and
        -- GUI:CursorPos(frame), which divides by the FRAME's own effective scale
        -- rather than UIParent's -- so it is indifferent to what it is parented
        -- to and to the settings window's user scale. The drag is clamped to the
        -- container's own rect (maxOffset in CreateGroupOrderList), so the ghost
        -- cannot leave its group, and the dragged item's frame level is set
        -- relative to the container rather than absolutely, so it rises above its
        -- siblings without punching through the card.
        local function BuildGroupOrderGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Drag to reorder groups. Top = first."], 250), 25)

            local playerGroupFirstCheck = group:AddWidget(GUI:CreateCheckbox(parent, L["My Group First"], db, "raidPlayerGroupFirst", function()
                if DF.UpdatePlayerGroupTracking then DF:UpdatePlayerGroupTracking() end
                if DF.UpdateRaidGroupOrderAttributes then DF:UpdateRaidGroupOrderAttributes() end
                DF:TriggerRaidPosition()
                UpdateFrames()
            end), 25)
            playerGroupFirstCheck.tooltip = L["When enabled, the group you are in will always be displayed first."]

            if not db.raidGroupDisplayOrder then
                db.raidGroupDisplayOrder = {1, 2, 3, 4, 5, 6, 7, 8}
            end

            local groupOrderWidget = GUI:CreateGroupOrderList(parent, db, "raidGroupDisplayOrder", function()
                if DF.UpdateRaidGroupOrderAttributes then DF:UpdateRaidGroupOrderAttributes() end
                DF:TriggerRaidPosition()
                UpdateFrames()
            end)
            group:AddWidget(groupOrderWidget, 230)
        end


        if classicLayout then
            local groupOrderGroup = GUI:CreateSettingsGroup(self.child, 280)
            groupOrderGroup:AddWidget(GUI:CreateHeader(self.child, L["Group Display Order"]), 40)
            groupOrderGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
            BuildGroupOrderGroup({
                group = groupOrderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(groupOrderGroup, nil, 2)
        else
            -- The order itself, which is the whole point of the group, plus the
            -- one qualifier that overrides it.
            local function GroupOrderSummary(d)
                if not d then return "" end
                local order = d.raidGroupDisplayOrder
                local parts = {}
                if type(order) == "table" and #order > 0 then
                    local seen, out = {}, {}
                    for _, n in ipairs(order) do
                        n = tonumber(n)
                        if n and n >= 1 and n <= 8 and not seen[n] then
                            seen[n] = true
                            out[#out + 1] = n
                        end
                    end
                    for i = 1, 8 do
                        if not seen[i] then out[#out + 1] = i end
                    end
                    parts[#parts + 1] = table.concat(out, " ")
                end
                if d.raidPlayerGroupFirst then parts[#parts + 1] = L["My Group First"] end
                return table.concat(parts, " \194\183 ")
            end

            -- Raid + groups only, header and band together, as the box. Which
            -- order the groups come in is behaviour, so no pin. The 230px drag
            -- list is a full row of its own (it binds no single value).
            local band = OpenSection(L["Group Display Order"], "frame_grouporder", 1, GroupOrderSummary, nil,
                function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end)
            BuildGroupOrderGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== FLAT GRID SETTINGS (a 280 box in classic, a raid card) ========
        -- Raid + FLAT only -- the opposite side of raidUseGroups from Group
        -- Layout Settings above, which is what keeps exactly one of the two on
        -- the page at a time.
        local function UpdateFlatLayoutFull()
            if InCombatLockdown() then return end
            if DF.headersInitialized then DF:ApplyHeaderSettings() end
            if GUI.SelectedMode == "raid" then DF:UpdateRaidLayout() end
        end

        local function BuildFlatGridGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["All players in a unified grid. Sorting applies raid-wide."], 250), 25)

            local playersPerLabel = db.growDirection == "VERTICAL" and L["Players Per Column"] or L["Players Per Row"]
            playersPerRowSlider = group:AddWidget(GUI:CreateSlider(parent, playersPerLabel, 1, 40, 1, db, "raidPlayersPerRow", UpdateFlatLayoutFull, UpdateFlatLayoutFull, true), 55)

            -- ☠ CROSS axis, NOT main -- these labels were MAIN_* and lied. GetGrowthAnchorPoint
            -- pins innerContainer to a CORNER of raidContainer, and the block always matches
            -- the container on the main axis (it is playersPerRow wide in Rows, five tall in
            -- Columns), so only the cross component can move: END is BOTTOMLEFT in Rows and
            -- TOPRIGHT in Columns. With MAIN_* the dropdown offered "Right" for Rows and moved
            -- the grid DOWN. The sibling below is also cross-axis and that is not a duplicate:
            -- this one ALIGNS the block in the reserved space, that one picks which end rows
            -- stack FROM.
            local growthAnchorOptions = { _order = { "START", "CENTER", "END" }, START= CROSS_START, CENTER= L["Center"], END= CROSS_END }
            group:AddWidget(GUI:CreateDropdown(parent, L["Grid Alignment"], growthAnchorOptions, db, "raidFlatGrowthAnchor", UpdateFrames), 55)

            -- Columns/Rows Grow From = the direction the grid wraps (secondary axis).
            -- VERTICAL (Columns) wraps left/right; HORIZONTAL (Rows) wraps top/bottom.
            local flatColumnLabel = db.growDirection == "VERTICAL" and L["Columns Grow From"] or L["Rows Grow From"]
            local flatColumnOptions = { _order = { "START", "END" }, START= CROSS_START, END= CROSS_END }
            group:AddWidget(GUI:CreateDropdown(parent, flatColumnLabel, flatColumnOptions, db, "raidFlatColumnAnchor", UpdateFrames), 55)

            -- Players Grow From = the direction players fill the grid's main axis.
            -- HORIZONTAL (Rows) fills Left/Right; VERTICAL (Columns) fills Top/Bottom.
            -- Replaces the old "Reverse Order" checkbox; START/END values are identical.
            -- ⚠ MAIN axis -- the OPPOSITE of the grouped Players Grow From, which is CROSS.
            local flatFillOptions = { _order = { "START", "END" }, START= MAIN_START, END= MAIN_END }
            group:AddWidget(GUI:CreateDropdown(parent, L["Players Grow From"], flatFillOptions, db, "raidFlatFrameAnchor", UpdateFrames), 55)

            group:AddWidget(GUI:CreateSlider(parent, L["Horizontal Spacing"], -5, 100, 1, db, "raidFlatHorizontalSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Vertical Spacing"], -5, 100, 1, db, "raidFlatVerticalSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        end

        if classicLayout then
            local flatGridGroup = GUI:CreateSettingsGroup(self.child, 280)
            flatGridGroup:AddWidget(GUI:CreateHeader(self.child, L["Flat Grid Settings"]), 40)
            flatGridGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end
            BuildFlatGridGroup({
                group = flatGridGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(flatGridGroup, nil, 1)
        else
            -- Two items, and the first deliberately borrows the word the GROUPED
            -- card uses for its own wrap count: one says how many groups fit
            -- before the block wraps, the other how many players do, and the two
            -- are never on screen together. The second is where the block sits in
            -- the reserved area. The edge words are derived from `d`, not from the
            -- build-time CROSS_ locals, for the Layout Direction summary's reason.
            local function FlatGridSummary(d)
                if not d then return "" end
                local parts = {}
                parts[#parts + 1] = format("%s %d", L["Wrap"], tonumber(d.raidPlayersPerRow) or 1)
                local vert = d.growDirection == "VERTICAL"
                local a = d.raidFlatGrowthAnchor or "START"
                parts[#parts + 1] = (a == "CENTER" and L["Center"])
                                 or (a == "END" and (vert and L["Right"] or L["Bottom"]))
                                 or (vert and L["Left"] or L["Top"])
                return table.concat(parts, " \194\183 ")
            end

            -- Raid + FLAT only, header and band together -- the opposite side of
            -- raidUseGroups from Group Layout Settings, so exactly one of the two
            -- is ever on the page. How the grid is laid out is how it LOOKS, so it
            -- is pinnable.
            local band = OpenSection(L["Flat Grid Settings"], "frame_flatgrid", 1, FlatGridSummary, nil,
                function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end, BuildFlatGridGroup)
            BuildFlatGridGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end
        
        -- Update labels on show.
        -- ⚠ THE THREE UPVALUES NOW POINT INTO WHICHEVER GROUP WAS BUILT LAST. In
        -- classic that is the one box each; in Modern it is the card, built after
        -- its pin's eager copy. A later pinned instance re-points them, and that
        -- is harmless: the only thing the hook does is re-read
        -- db.growDirection and re-label the flat grid's slider, so the worst case
        -- is the hook firing for the other copy of the same control.
        if groupsPerRowSlider and groupsPerRowSlider.label then
            groupsPerRowSlider:HookScript("OnShow", UpdateDynamicLabels)
        end
        if rowColSpacingSlider and rowColSpacingSlider.label then
            rowColSpacingSlider:HookScript("OnShow", UpdateDynamicLabels)
        end
        if playersPerRowSlider and playersPerRowSlider.label then
            playersPerRowSlider:HookScript("OnShow", UpdateDynamicLabels)
        end

        -- ===== PERMANENT MOVER (Column 2 box in classic, a card in Modern) =====
        -- ONE checkbox that means "am I doing anything", and fifteen controls that
        -- grey behind it: in Modern that checkbox is the card's header tick.
        --
        -- Declared out here rather than inside the builder because the SUMMARY
        -- reads it too: the card says which corner the handle sits in, and there
        -- is one map of those words on this page, not two.
        local moverAnchorValues = {
            TOPLEFT= L["Top Left"], TOP= L["Top"], TOPRIGHT= L["Top Right"],
            LEFT= L["Left"], RIGHT= L["Right"],
            BOTTOMLEFT= L["Bottom Left"], BOTTOM= L["Bottom"], BOTTOMRIGHT= L["Bottom Right"],
        }

        -- Verbatim, less the enable checkbox when the card's header carries it.
        -- Every widget keeps its own `disableOn` on permanentMover: that is what
        -- greys the body behind the header tick in Modern and the box in classic,
        -- one builder carrying the behaviour of both. Guarded by
        -- test_frame_page_builders.lua against the inventory it had inline.
        local function BuildPermanentMoverGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Permanent Mover"], db, "permanentMover", function()
                    DF:UpdatePermanentMoverVisibility()
                end), 30)
            end

            local permMoverAnchor = group:AddWidget(
                GUI:CreateDropdown(parent, L["Handle Position"], moverAnchorValues, db, "permanentMoverAnchor", function()
                    DF:UpdatePermanentMoverAnchor(GUI.SelectedMode)
                end), 55)
            permMoverAnchor.disableOn = function(d) return not d.permanentMover end

            local attachValues = { CONTAINER= L["Container"], FIRST= L["First Unit"], LAST= L["Last Unit"] }
            local permAttach = group:AddWidget(
                GUI:CreateDropdown(parent, L["Attach To"], attachValues, db, "permanentMoverAttachTo", function()
                    DF:UpdatePermanentMoverAnchor(GUI.SelectedMode)
                end), 55)
            permAttach.disableOn = function(d) return not d.permanentMover end
            permAttach.tooltip = L["Attach the handle to the container, the first visible unit, or the last visible unit."]

            local function PermMoverAnchorUpdate() DF:UpdatePermanentMoverAnchor(GUI.SelectedMode) end
            local function PermMoverSizeUpdate() DF:UpdatePermanentMoverSize(GUI.SelectedMode) end

            local permOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -500, 500, 1, db, "permanentMoverOffsetX", PermMoverAnchorUpdate, PermMoverAnchorUpdate), 55)
            permOffsetX.disableOn = function(d) return not d.permanentMover end

            local permOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -500, 500, 1, db, "permanentMoverOffsetY", PermMoverAnchorUpdate, PermMoverAnchorUpdate), 55)
            permOffsetY.disableOn = function(d) return not d.permanentMover end

            local permWidth = group:AddWidget(GUI:CreateSlider(parent, L["Handle Width"], 5, 500, 1, db, "permanentMoverWidth", PermMoverSizeUpdate, PermMoverSizeUpdate), 55)
            permWidth.disableOn = function(d) return not d.permanentMover end

            local permHeight = group:AddWidget(GUI:CreateSlider(parent, L["Handle Height"], 5, 500, 1, db, "permanentMoverHeight", PermMoverSizeUpdate, PermMoverSizeUpdate), 55)
            permHeight.disableOn = function(d) return not d.permanentMover end

            local permHover = group:AddWidget(GUI:CreateCheckbox(parent, L["Show on Hover Only"], db, "permanentMoverShowOnHover", function()
                DF:UpdatePermanentMoverVisibility()
            end), 30)
            permHover.disableOn = function(d) return not d.permanentMover end
            permHover.tooltip = L["Handle is invisible until you hover over it. Fades in and out smoothly."]

            local permCombat = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide in Combat"], db, "permanentMoverHideInCombat", function()
                DF:UpdatePermanentMoverCombatState()
            end), 30)
            permCombat.disableOn = function(d) return not d.permanentMover end
            permCombat.tooltip = L["Hides the handle during combat. If disabled, the handle changes color to indicate it is locked."]

            local permColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Handle Color"], db, "permanentMoverColor", false, function()
                DF:UpdatePermanentMoverColor(GUI.SelectedMode)
            end), 35)
            permColor.disableOn = function(d) return not d.permanentMover end

            local permCombatColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Combat Color"], db, "permanentMoverCombatColor", false, nil), 35)
            permCombatColor.disableOn = function(d) return not d.permanentMover end
            permCombatColor.tooltip = L["Color shown when in combat to indicate the handle is locked."]

            -- Quick action dropdowns
            local actionValues = {}
            for id, data in pairs(DF.PERM_MOVER_ACTIONS) do
                actionValues[id] = data.label
            end

            local permActionLeft = group:AddWidget(GUI:CreateDropdown(parent, L["Left Click"], actionValues, db, "permanentMoverActionLeft"), 55)
            permActionLeft.disableOn = function(d) return not d.permanentMover end

            local permActionRight = group:AddWidget(GUI:CreateDropdown(parent, L["Right Click"], actionValues, db, "permanentMoverActionRight"), 55)
            permActionRight.disableOn = function(d) return not d.permanentMover end

            local permActionShiftLeft = group:AddWidget(GUI:CreateDropdown(parent, L["Shift+Left Click"], actionValues, db, "permanentMoverActionShiftLeft"), 55)
            permActionShiftLeft.disableOn = function(d) return not d.permanentMover end

            local permActionShiftRight = group:AddWidget(GUI:CreateDropdown(parent, L["Shift+Right Click"], actionValues, db, "permanentMoverActionShiftRight"), 55)
            permActionShiftRight.disableOn = function(d) return not d.permanentMover end

            local permPullTimer = group:AddWidget(GUI:CreateSlider(parent, L["Pull Timer Duration"], 3, 30, 1, db, "permanentMoverPullTimerDuration"), 55)
            permPullTimer.disableOn = function(d) return not d.permanentMover end
            permPullTimer.tooltip = L["Duration in seconds for the Pull Timer quick action."]
        end

        if classicLayout then
            local permMoverGroup = GUI:CreateSettingsGroup(self.child, 280)
            permMoverGroup:AddWidget(GUI:CreateHeader(self.child, L["Permanent Mover"]), 40)
            BuildPermanentMoverGroup({ group = permMoverGroup, parent = self.child })
            Add(permMoverGroup, nil, 2)
        else
            -- The summary: where the handle is, how big it is, and what it is
            -- attached to when that is not the default. Three items, fixed order,
            -- words localised and numbers raw -- the attach word only when it is
            -- doing something. A shut card reads "Off" while the mover is off.
            local function PermMoverSummary(d)
                if not d then return "" end
                local parts = {}
                local pos = d.permanentMoverAnchor and moverAnchorValues[d.permanentMoverAnchor]
                if pos then parts[#parts + 1] = pos end
                local w, h = tonumber(d.permanentMoverWidth), tonumber(d.permanentMoverHeight)
                if w and h then
                    parts[#parts + 1] = format("%dx%d", math.floor(w), math.floor(h))
                end
                local attach = d.permanentMoverAttachTo
                if attach == "FIRST" then parts[#parts + 1] = L["First Unit"]
                elseif attach == "LAST" then parts[#parts + 1] = L["Last Unit"] end
                return table.concat(parts, " \194\183 ")
            end

            -- The category header the mover card sits under: the card's own
            -- title says "Permanent Mover", so the header names what the section
            -- is ABOUT, as the band's did.
            Add(GUI:CreateHeader(self.child, L["Movement"]), 40, 1)
            -- ☠ ENABLE PERMANENT MOVER IS THE HEADER'S TICK, so the builder is told
            -- not to build its own (hoistToggle). Every control in the body keeps
            -- its own disableOn on permanentMover, so the fifteen grey behind the
            -- tick through the state pass the commit runs -- never a page rebuild.
            -- A drag handle and its click actions are behaviour, so no pin.
            local band = OpenSection(L["Permanent Mover"], "frame_permanentmover", 1, PermMoverSummary, nil, nil, nil, {
                db = db, key = "permanentMover", label = L["Enable Permanent Mover"],
                onChanged = function()
                    DF:UpdatePermanentMoverVisibility()
                    self:RefreshStates()
                end,
            })
            BuildPermanentMoverGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- ===== NO BAND TAIL ================================================
        -- A card's band holds one group and is Add'd by CloseSection the moment
        -- that group is built, so nothing is deferred to here. Layout and Movement
        -- down the left, Appearance down the right; on a narrow window the page
        -- folds to one column in the order the cards were built -- the layout
        -- chain first, then how the frames look, then the mover. Classic does its
        -- own two-column Add above, with fixed 280 boxes.

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
