-- Part 3 of the settings pages, split from Options.lua.
-- The parts run as a chain so the pages build in their original order.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local format = string.format
function DF._SetupGUIPagesPart3(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
    pagePinnedFrames:SetScript("OnHide", function()
        if DF.PinnedFrames then
            DF.PinnedFrames:HidePreview()
        end
    end)

    -- General > Sorting
    local pageSorting = CreateSubTab("general", "general_sorting", L["Sorting"])
    BuildPage(pageSorting, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        -- "useFrameSort" is the FrameSort integration toggle — a real per-mode key
        -- that no prefix reached. (selfPosition / rolePriority / classPriority match
        -- nothing: those settings are stored as sort*, which the first prefix covers.
        -- Harmless, kept so the intent of the list stays readable.)
        Add(CreateCopyButton(self.child, {"sort", "useFrameSort", "selfPosition", "rolePriority", "classPriority"}, L["Sorting"], "general_sorting"), 25, 2)
        
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
        AddSpace(GUI.Space.block, "both")
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
        -- No copy-to-other-mode button: the only settings on this page are the
        -- colour-picker toggles, and those are account-wide now (see below), so
        -- there is nothing per-mode left to copy.
        -- ===== COLOR PICKER GROUP (Column 1) =====
        -- Bound to the ACCOUNT-WIDE db, not the page's per-mode `db`. These render
        -- on both the Party and Raid tabs, and when they were per-mode the Raid copy
        -- was write-only -- the hooks only ever read party, so ticking it on Raid
        -- looked enabled and did nothing. One setting, one value, both tabs.
        local pickerDB = DF:GetGlobalDB()
        local colorPickerGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorPickerGroup:AddWidget(GUI:CreateHeader(self.child, L["Color Picker"]), 40)

        colorPickerGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use DF Color Picker"], pickerDB, "colorPickerOverride", function()
            if pickerDB.colorPickerOverride or pickerDB.colorPickerGlobalOverride then
                GUI:InstallColorPickerHook()
            else
                GUI:UninstallColorPickerHook()
            end
            if pickerDB.colorPickerOverride then
                DF:Say("Color picker override enabled")
            else
                DF:Say("Color picker override disabled", nil, "WARN")
            end
        end), 30)
        colorPickerGroup:AddWidget(GUI:CreateLabel(self.child, L["Replace Blizzard's color picker with the DandersFrames color picker for this addon."], 250), 40)

        colorPickerGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Use DF Color Picker for All Addons"], pickerDB, "colorPickerGlobalOverride", function()
            if pickerDB.colorPickerOverride or pickerDB.colorPickerGlobalOverride then
                GUI:InstallColorPickerHook()
            else
                GUI:UninstallColorPickerHook()
            end
            if pickerDB.colorPickerGlobalOverride then
                DF:Say("Custom color picker enabled for all addons")
            else
                DF:Say("Custom color picker disabled for all addons", nil, "WARN")
            end
        end), 30)
        colorPickerGroup:AddWidget(GUI:CreateLabel(self.child, L["Show the DF color picker when any addon opens a color picker."], 250), 30)

        Add(colorPickerGroup, nil, 1)
        
        -- (Masque Integration group removed on 12.1: Masque cannot skin the
        -- native container aura buttons — its script hooks and backdrops are
        -- blocked on the protected buttons — so the toggle had no effect.)

        -- (Click-Through Icons group removed on 12.1: the container aura buttons
        -- are always click-through by design — Blizzard's AlwaysPropagateInput +
        -- the factory's unconditional SetMouseClickEnabled(false) — so the toggle
        -- had no effect. Tooltips are governed by the Tooltips page instead.)

        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buff Bar"]},
            {pageId = "auras_debuffs", label = L["Debuff Bar"]},
            {pageId = "auras_defensiveicon", label = L["Defensive Icon"]},
            -- DEPRECATED-TARGETED-SPELLS: link dropped with the sidebar row.
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

        -- ===== Column 1 (cont.): Dispel Colours =====
        -- Account-wide per-dispel-type palette (DF.db.dispelColors), the single source of
        -- truth for both the debuff-icon border and the dispel overlay. Defaults ARE the
        -- game palette (GetGameDispelPalette, queried from AuraUtil), so an untouched
        -- palette matches the game exactly; the overlay always follows it, the icon when
        -- "Color by Dispel Type" is on. No None/Physical picker — that border is hidden on
        -- no-dispel-type auras and the overlay never fires on them. Editing re-drives frames.
        local dispelColorsDB = DF.db.dispelColors
        if type(dispelColorsDB) ~= "table" then
            DF.db.dispelColors = {}
            dispelColorsDB = DF.db.dispelColors
        end
        local dispelGamePalette = DF:GetGameDispelPalette()
        local DISPEL_LIST = {
            { key = "Magic",   name = L["Magic"] },
            { key = "Curse",   name = L["Curse"] },
            { key = "Disease", name = L["Disease"] },
            { key = "Poison",  name = L["Poison"] },
            { key = "Bleed",   name = L["Bleed / Enrage"] },
        }
        -- Commit: bump the curve generation, rebuild the container rows (fresh
        -- SetAuraBorder binds pick up the new curve) and restyle the overlay
        -- (its binds re-run via the generation gate).
        local function DispelColorChanged()
            if DF.InvalidateDispelColorCurve then DF:InvalidateDispelColorCurve() end
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            if DF.UpdateAllFrames then DF:UpdateAllFrames() end
            if DF.LightweightUpdateDispelOverlay then DF:LightweightUpdateDispelOverlay() end
        end
        -- Live (colour-wheel drag): cheap path — the overlay re-binds via the
        -- generation gate and test-mode rings repaint on their ticker; live row
        -- rings catch up on commit (a native bind can't retint per drag frame).
        local function DispelColorLive()
            if DF.InvalidateDispelColorCurve then DF:InvalidateDispelColorCurve() end
            if DF.LightweightUpdateDispelOverlay then DF:LightweightUpdateDispelOverlay() end
        end
        local dispelCol = GUI:CreateSettingsGroup(self.child, 280)
        dispelCol:AddWidget(GUI:CreateHeader(self.child, L["Dispel Type Colors"]), 40)
        dispelCol:AddWidget(GUI:CreateLabel(self.child, L["Colours for each dispel type, used by the dispel overlay and the debuff-icon border (when Color by Dispel Type is on). Reset restores the game's colours."], 260), 55)
        local dispelResetBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        GUI:StyleButton(dispelResetBtn, { width = 260, height = 24, text = L["Reset All to Default"] })
        dispelResetBtn:SetScript("OnClick", function()
            for _, info in ipairs(DISPEL_LIST) do
                local d = dispelGamePalette[info.key]
                if d then dispelColorsDB[info.key] = { r = d.r, g = d.g, b = d.b } end
            end
            DispelColorChanged()
            if pageColors and pageColors.Refresh then pageColors:Refresh() end
        end)
        dispelCol:AddWidget(dispelResetBtn, 30)
        for i = 1, #DISPEL_LIST do
            local info = DISPEL_LIST[i]
            if type(dispelColorsDB[info.key]) ~= "table" then
                local d = dispelGamePalette[info.key]
                if d then dispelColorsDB[info.key] = { r = d.r, g = d.g, b = d.b } end
            end
            dispelCol:AddWidget(GUI:CreateColorPicker(self.child, info.name, dispelColorsDB, info.key, false, DispelColorChanged, DispelColorLive, true), 30)
        end
        Add(dispelCol, nil, 1)

        -- ===== Column 2 (cont.): Color by Time Remaining =====
        -- Account-wide duration-colour breakpoints, shared by the buff / debuff / defensive
        -- rows AND the Aura Designer wherever "Color by Time Remaining" is enabled. Each stop
        -- colours the duration text from its threshold upward; the highest threshold at or below
        -- the time left wins. Editing here re-drives the aura formatters live (no /reload).
        --
        -- Hybrid editor: a read-only preview strip (low time on the left, high on the right)
        -- over one row per stop. Each row reuses CreateColorPicker with its LABEL set to the
        -- human range it covers ("8s and above", "5-8s", "under 2s"), and a small +/- stepper
        -- moves that stop's lower boundary. Colour edits re-tint the strip in place; boundary
        -- add/remove/reset rebuild the page so every range label and the strip stay in sync.
        -- TWO SECTIONS, one per consumer: duration TEXT and the expiry BORDER/TINT reveal.
        -- An aura page only carries an on/off; everything about HOW the colour is read
        -- lives here with the colours it reads, because that is a property of the ramp.
        --   TEXT    blends or steps (12.1's colour curve), on either scale.
        --   BORDER  steps only — its colours are baked into |T inline-texture escapes,
        --           which ignore the fontstring vertex colour a curve writes.
        -- Each section keeps ONE stop list PER SCALE: thresholds cannot be reinterpreted
        -- between units (8 seconds is not 8 percent), so switching the scale swaps which
        -- ramp is being edited and leaves the other untouched for switching back.
        local cbtGlobalDB = DF:GetGlobalDB()
        local iconPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

        local CBT_UNITS = {
            SECONDS = { maxT = nil, capT = 600,   -- seconds have no natural ceiling; derive from the stops
                        above = L["%ds and above"], under = L["under %ds"], range = L["%d-%ds"] },
            PERCENT = { maxT = 100, capT = 100,
                        above = L["%d%% and above"], under = L["under %d%%"], range = L["%d-%d%%"] },
        }
        -- ONE RAMP PER UNIT, shared by every colour-by-time consumer — the duration text
        -- AND the expiry border/tint reveal. "Time is running out" is one idea, so it gets
        -- one set of colours. BOTH ramps are live at once: duration text reads whichever
        -- its s/% toggle names (it has no threshold, so that is account-wide), while each
        -- expiry reveal reads the one matching ITS OWN unit — per indicator, because a
        -- reveal's bands and its Alert Below threshold are one formatter sampled against
        -- one property.
        local CBT_RAMPS = {
            SECONDS = { bpKey = "durationColorByTimeBreakpoints" },
            PERCENT = { bpKey = "durationColorByPercentBreakpoints" },
        }

        local function ApplyColorByTime()
            if DF.InvalidateDurationFormatters then DF:InvalidateDurationFormatters() end
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            if DF.UpdateAllFrames then DF:UpdateAllFrames() end
            if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
            -- Expiry reveals read these ramps too, so an open Aura Designer card must
            -- re-render its preview (no-ops if the designer was never opened).
            if DF.AuraDesigner_RefreshPage then DF:AuraDesigner_RefreshPage() end
        end

        -- The colour swatch fires its callback on EVERY change (many ticks per wheel drag),
        -- so debounce the heavy re-drive: only the settled colour rebuilds the containers.
        -- (add/remove/reset call ApplyColorByTime directly — discrete, no debounce needed.)
        local cbtApplyTimer
        local function ScheduleColorApply()
            if cbtApplyTimer then cbtApplyTimer:Cancel() end
            cbtApplyTimer = C_Timer.NewTimer(0.2, function()
                cbtApplyTimer = nil
                ApplyColorByTime()
            end)
        end

        -- Page-level collapsible section wrapping BOTH boxes, matching Health Bar and
        -- friends. Its title is also the cross-link anchor every aura page flashes
        -- (GUI:CreateColorsPageLink -> LinkToSetting{ section = L["Color by Time"] }) —
        -- keep the two in step if it is ever renamed. Assigned just before the build
        -- loop so it lands on the page ABOVE the boxes it owns.
        local cbtSection

        -- ONE box (design "A"): Seconds/Percent TABS pick which unit's stops are being
        -- EDITED (self._cbtEditUnit — page-local UI state, deliberately not saved), the
        -- editor strip under them always shows HARD BANDS (the stops are data; how a
        -- consumer renders them is the legend's job), and the "How this renders" legend
        -- at the bottom is FIXED: a labelled preview per consumer, with that consumer's
        -- own dials beside it. The previous layout drew the gradient on whichever ramp
        -- the text happened to read, so flipping the text's unit visibly moved the
        -- gradient between boxes — correct data, but it read as a bug.
        local function BuildSection()
        local editUnit = (self._cbtEditUnit == "PERCENT") and "PERCENT" or "SECONDS"
        self._cbtEditUnit = editUnit
        local scale = CBT_UNITS[editUnit]
        local bpKey = CBT_RAMPS[editUnit].bpKey

        -- Seed BOTH ramps: the legend previews can show the non-edited unit (the text
        -- preview always renders the ramp the text actually reads), so both lists must
        -- exist whichever tab is up.
        for _, ramp in pairs(CBT_RAMPS) do
            if type(cbtGlobalDB[ramp.bpKey]) ~= "table" or #cbtGlobalDB[ramp.bpKey] == 0 then
                cbtGlobalDB[ramp.bpKey] = DF:DeepCopy(DF.GlobalDefaults[ramp.bpKey])
            end
        end
        local bps = cbtGlobalDB[bpKey]

        local function cbtT(s) return math.max(0, tonumber(s and s.threshold) or 0) end
        local function cbtSorted(descending)
            local out = {}
            for _, s in ipairs(bps) do out[#out + 1] = s end
            table.sort(out, function(a, b)
                if descending then return cbtT(a) > cbtT(b) else return cbtT(a) < cbtT(b) end
            end)
            return out
        end

        local cbtGroup = GUI:CreateSettingsGroup(self.child, 280)

        -- Tabs: which unit's stops are on the editor below. UI state only — flipping a
        -- tab changes nothing about what renders in the world. Underline-tab style
        -- (StyleButton opts.tab — the PARTY/RAID/BINDS look), half-width each so the
        -- pair spans the box. No explicit accent: the tab picks up the mode accent
        -- (party purple / raid), same as the main tabs. CreateSegmentToggle stays the
        -- compact value toggle beside a control (the s/% dials in the legend below).
        local tabRow = CreateFrame("Frame", nil, self.child)
        tabRow:SetSize(260, 24)
        local prevTab
        for _, def in ipairs({
            { key = "SECONDS", label = L["Seconds"] },
            { key = "PERCENT", label = L["Percent"] },
        }) do
            local tabBtn = CreateFrame("Button", nil, tabRow, "BackdropTemplate")
            GUI:StyleButton(tabBtn, { tab = true, width = 128, height = 24, text = def.label, font = "DFFontHighlight" })
            if prevTab then
                tabBtn:SetPoint("LEFT", prevTab, "RIGHT", 4, 0)
            else
                tabBtn:SetPoint("LEFT", tabRow, "LEFT", 0, 0)
            end
            local key = def.key
            tabBtn:SetScript("OnClick", function()
                if self._cbtEditUnit ~= key then
                    self._cbtEditUnit = key
                    if pageColors and pageColors.Refresh then pageColors:Refresh() end
                end
            end)
            tabBtn:SetActive(editUnit == key)
            prevTab = tabBtn
        end
        cbtGroup:AddWidget(tabRow, 30)

        -- Strip builder, shared by the editor strip and the legend previews. `unit` picks
        -- which ramp the strip shows — the editor and border previews show the EDITED
        -- unit, the text preview always shows the ramp the TEXT reads. smoothMode marks
        -- the strips that render the way the duration text does (gradient while Blend
        -- Colors Smoothly is on). Low values left, high right.
        local previewW, stripH = 256, 18
        local strips = {}
        local function BuildStrip(w, h, smoothMode, unit)
            local f = CreateFrame("Frame", nil, self.child)
            f:SetSize(w, h)
            f.segs, f.smoothMode = {}, smoothMode
            local asc = {}
            for _, s2 in ipairs(cbtGlobalDB[CBT_RAMPS[unit].bpKey]) do asc[#asc + 1] = s2 end
            table.sort(asc, function(a, b) return cbtT(a) < cbtT(b) end)
            local maxT = CBT_UNITS[unit].maxT or math.max(12, cbtT(asc[#asc]) + 2)
            for k = 1, #asc do
                local lo = cbtT(asc[k])
                local hi = (k < #asc) and cbtT(asc[k + 1]) or maxT
                if hi > lo then
                    local tex = f:CreateTexture(nil, "ARTWORK")
                    tex:SetPoint("TOPLEFT", f, "TOPLEFT", (lo / maxT) * w, 0)
                    tex:SetSize(((hi - lo) / maxT) * w, h)
                    tex:SetColorTexture(1, 1, 1, 1)   -- white base; the gradient tints it
                    f.segs[#f.segs + 1] = { tex = tex, from = asc[k], to = asc[k + 1] }
                end
            end
            strips[#strips + 1] = f
            return f
        end
        local function RefreshPreview()
            for _, f in ipairs(strips) do
                local sm = f.smoothMode and (cbtGlobalDB.durationTextColorSmooth ~= false)
                for _, seg in ipairs(f.segs) do
                    -- ONE path for both modes: reset the base to white, then gradient
                    -- a->b — stepped is just a->a, a solid band. The mode now flips at
                    -- RUNTIME (the Blend checkbox retints in place), and SetGradient
                    -- layered over a texture left as SetColorTexture(band colour)
                    -- MULTIPLIES the two into mud; the white reset makes every retint
                    -- idempotent. The band above the final stop stays flat because the
                    -- curve clamps there (probe-verified).
                    local a = seg.from.color or { r = 1, g = 1, b = 1 }
                    local b = (sm and seg.to and seg.to.color) or a
                    seg.tex:SetColorTexture(1, 1, 1, 1)
                    seg.tex:SetGradient("HORIZONTAL",
                        CreateColor(a.r or 1, a.g or 1, a.b or 1, 1),
                        CreateColor(b.r or 1, b.g or 1, b.b or 1, 1))
                end
            end
        end

        -- Editor strip: ALWAYS hard bands. The stops are the data being edited; whether a
        -- consumer blends them is that consumer's property, previewed in the legend below.
        cbtGroup:AddWidget(BuildStrip(previewW, stripH, false, editUnit), 24)
        RefreshPreview()

        -- ONE row per stop, freshest (highest threshold) first: colour chip, computed
        -- range, boundary stepper, remove. The chip IS a CreateColorPicker — shrunk to
        -- its swatch by resizing the container (the button anchors TOPLEFT/TOPRIGHT, so
        -- it follows) — which brings the whole dialog stack along (cancel restore,
        -- Default button, ElvUI hook, spurious open-fire suppression) instead of
        -- reimplementing any of it. The "Starts at" caption the merge dropped lives on
        -- as a tooltip on the stepper controls.
        local desc = cbtSorted(true)
        for i = 1, #desc do
            local bp = desc[i]
            if type(bp.color) ~= "table" then bp.color = { r = 1, g = 1, b = 1 } end
            local t = cbtT(bp)
            local above = (i > 1) and cbtT(desc[i - 1]) or nil
            local rangeLabel
            if i == 1 then
                rangeLabel = format(scale.above, t)
            elseif t == 0 then
                rangeLabel = format(scale.under, above or 0)
            else
                rangeLabel = format(scale.range, t, above or t)
            end

            local row = CreateFrame("Frame", nil, self.child)
            row:SetSize(previewW, 24)

            local chip = GUI:CreateColorPicker(self.child, "", bp, "color", false, function()
                RefreshPreview()
                ScheduleColorApply()
            end, nil, false)
            chip:SetParent(row)
            chip:SetSize(52, 24)
            chip:SetPoint("LEFT", row, "LEFT", 0, 0)

            local cap = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            cap:SetPoint("LEFT", chip, "RIGHT", 8, 0)
            cap:SetText(rangeLabel)
            cap:SetTextColor(0.85, 0.85, 0.85)
            cap:SetWordWrap(false)
            cap:SetJustifyH("LEFT")

            -- Boundary stepper (the t == 0 base band has no adjustable lower edge).
            -- +/- nudge by one; the middle field is typeable for big jumps (8 -> 120).
            if t ~= 0 then
                local lowerBound = (i < #desc) and (cbtT(desc[i + 1]) + 1) or 1
                -- The top stop is capped by the scale (100% has a real ceiling; seconds
                -- keep the long-buff headroom the field already allowed).
                local upperBound = (i > 1) and (cbtT(desc[i - 1]) - 1) or scale.capT

                local eb
                local function commitTo(nt)
                    nt = math.floor(tonumber(nt) or cbtT(bp))
                    nt = math.max(lowerBound, math.min(upperBound, nt))
                    if nt == cbtT(bp) then
                        if eb then eb:SetText(tostring(cbtT(bp))) end
                        return
                    end
                    bp.threshold = nt
                    ApplyColorByTime()
                    if pageColors and pageColors.Refresh then pageColors:Refresh() end
                end

                -- Right-to-left: [−][value][+][×], the × only when removable. Stepper
                -- rows all share the removable state, so their columns stay aligned.
                local rightAnchor, rightPoint, rightOff = row, "RIGHT", -2
                if #bps > 2 then
                    -- Reuse the shared close-X in its default (dismiss) form — grey glyph at
                    -- rest, white glyph + red hover wash on mouseover, exactly like the GUI's
                    -- own close button. (No tone="danger" — that tints the glyph red at rest.)
                    local remBtn = GUI:CreateCloseButton(row, {
                        size = 20,
                        onClick = function()
                            for idx, s in ipairs(bps) do
                                if s == bp then table.remove(bps, idx) break end
                            end
                            ApplyColorByTime()
                            if pageColors and pageColors.Refresh then pageColors:Refresh() end
                        end,
                    })
                    remBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
                    rightAnchor, rightPoint, rightOff = remBtn, "LEFT", -6
                end

                local plus = CreateFrame("Button", nil, row, "BackdropTemplate")
                GUI:StyleButton(plus, { width = 22, height = 20, icon = { texture = iconPath .. "add", size = 12, color = { r = 0.85, g = 0.85, b = 0.85 } } })
                plus:SetPoint("RIGHT", rightAnchor, rightPoint, rightOff, 0)
                plus:SetScript("OnClick", function() commitTo(cbtT(bp) + 1) end)

                eb = CreateFrame("EditBox", nil, row)
                GUI:StyleEditBox(eb)
                eb:SetSize(42, 20)
                eb:SetPoint("RIGHT", plus, "LEFT", -4, 0)
                eb:SetAutoFocus(false)
                eb:SetNumeric(true)
                eb:SetMaxLetters(4)
                eb:SetJustifyH("CENTER")
                eb:SetText(tostring(t))
                eb:SetCursorPosition(0)
                eb:SetScript("OnEnterPressed", function(self)
                    local text = self:GetText()
                    self:ClearFocus()
                    commitTo(text)
                end)
                eb:SetScript("OnEscapePressed", function(self)
                    self:SetText(tostring(cbtT(bp)))
                    self:ClearFocus()
                end)
                eb:SetScript("OnEditFocusLost", function(self)
                    self:SetText(tostring(cbtT(bp)))
                end)

                local minus = CreateFrame("Button", nil, row, "BackdropTemplate")
                GUI:StyleButton(minus, { width = 22, height = 20, icon = { texture = iconPath .. "remove", size = 12, color = { r = 0.85, g = 0.85, b = 0.85 } } })
                minus:SetPoint("RIGHT", eb, "LEFT", -4, 0)
                minus:SetScript("OnClick", function() commitTo(cbtT(bp) - 1) end)

                -- The merged row dropped the "Starts at" caption; the value box (only —
                -- the +/- explain themselves) says it on hover instead.
                eb:HookScript("OnEnter", function() GUI:ShowTooltip(eb, { title = L["Starts at"] }) end)
                eb:HookScript("OnLeave", function() GUI:HideTooltip() end)
                cap:SetPoint("RIGHT", minus, "LEFT", -6, 0)
            else
                cap:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            end
            cbtGroup:AddWidget(row, 28)
        end

        -- Add + Reset side by side: neither needs a full row to itself, and halving
        -- them buys back a row of the height the stop merge just saved.
        local stopBtnRow = CreateFrame("Frame", nil, self.child)
        stopBtnRow:SetSize(260, 24)
        local addStopBtn = CreateFrame("Button", nil, stopBtnRow, "BackdropTemplate")
        GUI:StyleButton(addStopBtn, { width = 127, height = 24, text = L["Add Color Stop"] })
        addStopBtn:SetPoint("LEFT", stopBtnRow, "LEFT", 0, 0)
        addStopBtn:SetScript("OnClick", function()
            -- Drop a new stop into the widest existing gap.
            local a2 = cbtSorted(false)
            local mx = scale.maxT or math.max(12, cbtT(a2[#a2]) + 2)
            local bestT, bestGap = nil, -1
            for k = 1, #a2 do
                local lo = cbtT(a2[k])
                local hi = (k < #a2) and cbtT(a2[k + 1]) or mx
                local mid = math.floor((lo + hi) / 2)
                if (hi - lo) > bestGap and mid > lo and mid < hi then
                    bestGap = hi - lo
                    bestT = mid
                end
            end
            if bestT then bps[#bps + 1] = { threshold = bestT, color = { r = 1, g = 1, b = 1 } } end
            ApplyColorByTime()
            if pageColors and pageColors.Refresh then pageColors:Refresh() end
        end)

        local resetStopsBtn = CreateFrame("Button", nil, stopBtnRow, "BackdropTemplate")
        GUI:StyleButton(resetStopsBtn, { width = 127, height = 24, text = L["Reset to Default"] })
        resetStopsBtn:SetPoint("RIGHT", stopBtnRow, "RIGHT", 0, 0)
        resetStopsBtn:SetScript("OnClick", function()
            wipe(bps)
            for _, dv in ipairs(DF.GlobalDefaults[bpKey]) do
                bps[#bps + 1] = { threshold = dv.threshold, color = { r = dv.color.r, g = dv.color.g, b = dv.color.b } }
            end
            ApplyColorByTime()
            if pageColors and pageColors.Refresh then pageColors:Refresh() end
        end)
        cbtGroup:AddWidget(stopBtnRow, 30)

        -- ── HOW THIS RENDERS ─────────────────────────────────────────────────────
        -- One labelled preview per consumer, each rendering the EDITED ramp through
        -- that consumer's lens, with the consumer's own dials on its row. This block
        -- never changes shape — only the pixels inside the previews.
        cbtGroup:AddWidget(GUI:CreateExpiringSubheader(self.child, L["How this renders"]), 26)

        -- Duration text: ALWAYS the ramp the text actually reads (its own unit, whatever
        -- tab is up), gradient while Blend is on. Never dimmed — this row answers "what
        -- does my countdown text look like right now", and its s/% toggle switches which
        -- ramp that is, which the preview shows by changing colours, not by greying.
        local textRow = CreateFrame("Frame", nil, self.child)
        textRow:SetSize(260, 22)
        local textLbl = textRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        textLbl:SetPoint("LEFT", 0, 0)
        textLbl:SetText(L["Duration Text"])
        textLbl:SetTextColor(0.85, 0.85, 0.85)
        local textUnitNow = (cbtGlobalDB.durationTextColorScale == "SECONDS") and "SECONDS" or "PERCENT"
        local textStrip = BuildStrip(108, 14, true, textUnitNow)
        textStrip:SetParent(textRow)
        textStrip:SetPoint("LEFT", textRow, "LEFT", 88, 0)
        local textUnit = GUI:CreateSegmentToggle(self.child, {
            { value = "SECONDS", label = L["s"], tooltip = L["Seconds"] },
            { value = "PERCENT", label = L["%"], tooltip = L["Percent"] },
        }, cbtGlobalDB, "durationTextColorScale", function()
            ApplyColorByTime()
            if pageColors and pageColors.Refresh then pageColors:Refresh() end
        end, { segmentWidth = 26, height = 18 })
        textUnit:SetParent(textRow)
        textUnit:SetPoint("RIGHT", textRow, "RIGHT", 0, 0)
        cbtGroup:AddWidget(textRow, 26)

        -- Blend belongs to the TEXT, so it sits inside the text block — above the note,
        -- not between the note and Border & Tint, where it read as a border dial (the
        -- exact opposite of what it is: borders can never blend). Each block here is
        -- "row, its dials, then its note", so the note is what closes a block.
        cbtGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Blend Colors Smoothly"], cbtGlobalDB,
            "durationTextColorSmooth", function()
                ApplyColorByTime()
                RefreshPreview()   -- rendering-only: retint the text preview in place
            end), 30)

        -- Covers BOTH dials above: durationTextColorScale and durationTextColorSmooth
        -- are account-wide, unlike the border's per-indicator unit — the pair of notes
        -- exists to make that contrast readable.
        cbtGroup:AddWidget(GUI:CreateNote(self.child, L["Shared by all duration text."],
            { width = 260 }))

        -- Border & tint: always hard bands (|T escapes ignore the vertex colour a curve
        -- writes), reading whichever ramp matches each indicator's own unit.
        local borderRow = CreateFrame("Frame", nil, self.child)
        borderRow:SetSize(260, 22)
        local borderLbl = borderRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        borderLbl:SetPoint("LEFT", 0, 0)
        borderLbl:SetText(L["Border & Tint"])
        borderLbl:SetTextColor(0.85, 0.85, 0.85)
        local borderStrip = BuildStrip(108, 14, false, editUnit)
        borderStrip:SetParent(borderRow)
        borderStrip:SetPoint("LEFT", borderRow, "LEFT", 88, 0)
        local borderTag = borderRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        borderTag:SetPoint("RIGHT", borderRow, "RIGHT", -2, 0)
        borderTag:SetText(L["steps"])
        borderTag:SetTextColor(0.55, 0.55, 0.55)
        cbtGroup:AddWidget(borderRow, 26)
        cbtGroup:AddWidget(GUI:CreateNote(self.child,
            L["Set per indicator. Can't blend colors — always steps."],
            { width = 260 }))

        RefreshPreview()   -- tint the legend strips built after the first pass
        Add(cbtGroup, nil, 2)
        if cbtSection then cbtSection:RegisterChild(cbtGroup) end
        end   -- BuildSection

        -- Column 2, not "both": the header belongs over the box it owns rather than
        -- spanning the page (column 1 holds the dispel palette, which it does not own).
        -- Width matches the box so the rule under the title lines up with it.
        cbtSection = Add(GUI:CreateCollapsibleSection(self.child, L["Color by Time"], true, 280), 36, 2)
        BuildSection()
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
        
        -- ===== GRADIENT GROUP (Column 1, conditional) =====
        -- ☠ WAS A FULL-WIDTH HEADER, A 550px BAR AND THREE 280px GROUPS -- roughly 500px
        -- of page across both columns for what is one ramp. It is one box under Color
        -- now, in column 1, and the ramp is a STOP LIST rather than three fixed stages
        -- with weights: any number of stops, each with its own threshold.
        --
        -- Modelled on the Color by Time editor further up this file, deliberately -- same
        -- preview-strip-over-rows shape, same 52px colour chip, same +/- stepper, same
        -- add/reset footer. Two editors for "a colour ramp with stops" that look
        -- different would be two things to learn.
        --
        -- ⚠ The 550px bar was ALSO the widget that misbehaved on window drag, because a
        -- full-width widget is resized on every relayout. This one is fixed at the box's
        -- inner width, and CreateGradientBar repaints on OnSizeChanged regardless.
        --
        -- ★ ONE BUILDER, BOTH BARS. The health bar and the missing-health fill each keep
        -- a stop list under this same editor; only the key prefix and the visibility
        -- rule differ. The first version was built for the health bar alone, and the
        -- missing-health section kept its old Low/Medium/High stage groups -- which by
        -- then were editing legacy keys the renderer no longer reads on any migrated
        -- profile (BuildColorStops resolves <prefix>Stops first). The body keeps the
        -- surrounding indent so the factoring reads as what it is in the diff.
        local function BuildGradientStopBox(prefix, hideOn)
        local listKey = prefix .. "Stops"
        local gradGroup = GUI:CreateSettingsGroup(self.child, 280)
        gradGroup:AddWidget(GUI:CreateHeader(self.child, L["Gradient"]), 40)
        local gradInner = GUI:GroupInnerWidth(gradGroup)
        -- Own copy: the Colors page's `iconPath` is a local inside ITS BuildPage closure,
        -- so it is not in scope here. Reaching for it would resolve to a nil global.
        local gradIconPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

        -- ⚠ Mode-correct defaults, not PartyDefaults unconditionally. RaidDefaults is a
        -- deep copy of PartyDefaults today, so the two agree on the stops and either
        -- would work -- but the moment a raid override is added for them, a hardcoded
        -- PartyDefaults would quietly seed party values into the raid profile. Same
        -- idiom Pages/Indicators.lua uses for its reset.
        local function GradDefaults()
            local d = (db == DF.db.raid) and DF.RaidDefaults or DF.PartyDefaults
            return DF:DeepCopy(d[listKey])
        end

        local function GradStops()
            local s = db[listKey]
            if type(s) ~= "table" or #s < 2 then
                -- ☠ CONVERT, DO NOT INVENT. This used to seed Config's new three-stop
                -- default here, and that was a real bug rather than a tidy fallback:
                -- opening this page on a profile the migration had not reached wrote
                -- three stops and SAVED them, and because the migration is
                -- presence-gated it then skipped that profile permanently. The user
                -- ended up with a flat 0/50/100 ramp and no way back -- for a default
                -- profile the honest answer is FIVE stops, from Low 2 / Medium 2 / High 1.
                --
                -- DF:LegacyStopsFor is the migration's own conversion, so the editor and
                -- the migration cannot disagree about what a profile's ramp is.
                s = DF.LegacyStopsFor and DF:LegacyStopsFor(db, prefix)
                db[listKey] = s or GradDefaults()
                s = db[listKey]
            end
            table.sort(s, function(a, b)
                return (tonumber(a.threshold) or 0) < (tonumber(b.threshold) or 0)
            end)
            return s
        end

        local gradBar = GUI:CreateGradientBar(self.child, gradInner, 18, db, prefix)
        gradGroup:AddWidget(gradBar, 24)

        -- Colour edits fire per wheel tick, so repaint the strip live but debounce the
        -- curve rebuild -- the same split the Color by Time editor uses.
        local function GradRepaint() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end
        local function GradApply()
            GradRepaint()
            DF:UpdateColorCurve()
            DF:RefreshAllVisibleFrames()
        end
        -- Adding, removing or moving a stop changes the ROW SET, so the page has to be
        -- rebuilt for the captions and stepper bounds to stay truthful. A colour edit
        -- does not, and must not — rebuilding under an open colour picker closes it.
        local function GradRebuild()
            GradApply()
            if pageHealthBar and pageHealthBar.Refresh then pageHealthBar:Refresh() end
        end

        do
            local stops = GradStops()
            for i, stop in ipairs(stops) do
                local row = CreateFrame("Frame", nil, self.child)
                row:SetSize(gradInner, 24)

                -- ★ THE SWATCH AND THE CLASS TOGGLE ARE ONE CONTROL. They sit flush, same
                -- height, and EXACTLY ONE OF THEM READS AS LIVE -- the inactive half dims.
                -- That is what stops it looking like two widgets: the pair answers a
                -- single question ("this colour, or the unit's class?") and shows which
                -- answer is current, rather than a swatch plus a floating tickbox.
                --
                -- Per stop, deliberately. The old three-stage model had a UseClass on each
                -- stage, and dropping to one ramp-wide toggle would have been a quiet
                -- capability loss.
                local chip = GUI:CreateColorPicker(self.child, "", stop, "color", false,
                    GradRepaint, GradApply, true)
                chip:SetParent(row)
                chip:SetSize(52, 24)
                chip:SetPoint("LEFT", row, "LEFT", 0, 0)

                local classBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
                classBtn:SetSize(20, 24)
                classBtn:SetPoint("LEFT", chip, "RIGHT", 0, 0)   -- flush: one unit
                GUI:CreateElementBackdrop(classBtn, {
                    fill        = true,
                    outline     = true,
                    bgColor     = { 0.14, 0.14, 0.14, 1 },
                    borderColor = { 0.23, 0.23, 0.23, 1 },
                })
                -- The toggle's own fill IS the player's class colour, so the control
                -- shows what it does instead of needing a letter on it -- and a glyph
                -- avoids inventing a localisable "C" that means nothing in most languages.
                local _, rowClass = UnitClass("player")
                local rowCC = rowClass and DF:GetClassColor(rowClass)
                local classTex = classBtn:CreateTexture(nil, "ARTWORK")
                classTex:SetPoint("TOPLEFT", 3, -3)
                classTex:SetPoint("BOTTOMRIGHT", -3, 3)
                classTex:SetColorTexture((rowCC and rowCC.r) or 0.6, (rowCC and rowCC.g) or 0.6,
                                         (rowCC and rowCC.b) or 0.6, 1)

                local function PaintClassPair()
                    local on = stop.useClass and true or false
                    -- Dim whichever half is not in play. The fixed swatch keeps its colour
                    -- (so you can still see what you would go back to) but drops to a
                    -- third alpha; the class square does the same in reverse.
                    chip:SetAlpha(on and 0.35 or 1)
                    classTex:SetAlpha(on and 1 or 0.25)
                end
                PaintClassPair()

                classBtn:SetScript("OnClick", function()
                    stop.useClass = not stop.useClass
                    PaintClassPair()
                    GradApply()   -- colour resolution only; must not rebuild the page
                end)
                classBtn:HookScript("OnEnter", function()
                    GUI:ShowTooltip(classBtn, { title = L["Use Class Color"],
                        lines = { L["Color this stop by each unit's own class."] } })
                end)
                classBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

                local cap = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                cap:SetPoint("LEFT", classBtn, "RIGHT", 8, 0)
                cap:SetText(format("%d%%", math.floor(tonumber(stop.threshold) or 0)))
                cap:SetTextColor(0.85, 0.85, 0.85)
                cap:SetWordWrap(false)
                cap:SetJustifyH("LEFT")

                -- Right to left: [x][+][value][-]. The end stops keep their thresholds:
                -- a ramp that does not start at 0 or reach 100 has to hold its end
                -- colours outward, which reads as a bug even though the renderer copes.
                local isEnd = (i == 1) or (i == #stops)
                local rightAnchor, rightPoint, rightOff = row, "RIGHT", -2

                if not isEnd then
                    local remBtn = GUI:CreateCloseButton(row, {
                        size = 20,
                        onClick = function()
                            for idx, s in ipairs(db[listKey]) do
                                if s == stop then table.remove(db[listKey], idx) break end
                            end
                            GradRebuild()
                        end,
                        -- `tooltip`, not `tooltipDesc`: CreateCloseButton gates the whole
                        -- hook on opts.tooltip, so a desc alone never rendered. Title-only
                        -- is the house style for a ✕ whose title says everything.
                        tooltip = L["Remove this stop"],
                    })
                    remBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
                    rightAnchor, rightPoint, rightOff = remBtn, "LEFT", -4
                end

                if not isEnd then
                    local cur = math.floor(tonumber(stop.threshold) or 0)
                    local lower = math.floor(tonumber(stops[i - 1].threshold) or 0) + 1
                    local upper = math.floor(tonumber(stops[i + 1].threshold) or 100) - 1
                    local eb
                    local function commitTo(nt)
                        nt = math.floor(tonumber(nt) or cur)
                        nt = math.max(lower, math.min(upper, nt))
                        if nt == cur then
                            -- Rejected or unchanged: put the field back to the truth,
                            -- otherwise a clamped entry sits there reading as accepted.
                            if eb then eb:SetText(tostring(cur)) end
                            return
                        end
                        stop.threshold = nt
                        GradRebuild()
                    end

                    local plus = CreateFrame("Button", nil, row, "BackdropTemplate")
                    GUI:StyleButton(plus, { width = 22, height = 20, icon = { texture = gradIconPath .. "add", size = 12, color = { r = 0.85, g = 0.85, b = 0.85 } } })
                    plus:SetPoint("RIGHT", rightAnchor, rightPoint, rightOff, 0)
                    plus:SetScript("OnClick", function() commitTo(cur + 1) end)

                    -- Typeable, not a label: a threshold runs 0-100, so nudging 50 to 90
                    -- on the +/- alone is forty clicks. Same EditBox shape the Color by
                    -- Time stepper uses, tooltip included -- the row has no width for a
                    -- caption beside it.
                    eb = CreateFrame("EditBox", nil, row)
                    GUI:StyleEditBox(eb)
                    eb:SetSize(38, 20)
                    eb:SetPoint("RIGHT", plus, "LEFT", -4, 0)
                    eb:SetAutoFocus(false)
                    eb:SetNumeric(true)
                    eb:SetMaxLetters(3)
                    eb:SetJustifyH("CENTER")
                    eb:SetText(tostring(cur))
                    eb:SetCursorPosition(0)
                    -- ☠ BOTH keys clear focus. An edit box that swallows Escape traps the
                    -- keypress so it never reaches the panel -- three of those were fixed
                    -- in this addon's dialogs recently; do not add a fourth.
                    -- ⚠ ClearFocus ONLY: it fires OnEditFocusLost, which commits. An
                    -- explicit commitTo here ran SECOND, against cur/lower/upper
                    -- captured before the focus-lost commit's rebuild -- a stale
                    -- double-commit per Enter press.
                    eb:SetScript("OnEnterPressed", function(s)
                        s:ClearFocus()
                    end)
                    eb:SetScript("OnEscapePressed", function(s)
                        s:SetText(tostring(cur))
                        s:ClearFocus()
                    end)
                    -- Commit on click-away too, not only Enter: a typed number that
                    -- silently reverted because you clicked elsewhere is the most
                    -- irritating way for a field like this to behave.
                    eb:SetScript("OnEditFocusLost", function(s) commitTo(s:GetText()) end)
                    eb:HookScript("OnEnter", function()
                        GUI:ShowTooltip(eb, { title = L["Starts at"] })
                    end)
                    eb:HookScript("OnLeave", function() GUI:HideTooltip() end)

                    local minus = CreateFrame("Button", nil, row, "BackdropTemplate")
                    GUI:StyleButton(minus, { width = 22, height = 20, icon = { texture = gradIconPath .. "remove", size = 12, color = { r = 0.85, g = 0.85, b = 0.85 } } })
                    minus:SetPoint("RIGHT", eb, "LEFT", -4, 0)
                    minus:SetScript("OnClick", function() commitTo(cur - 1) end)

                    cap:SetPoint("RIGHT", minus, "LEFT", -6, 0)
                else
                    cap:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                end

                -- ⚠ NO PER-STOP CLASS TICKBOX. One toggle for the whole ramp sits below
                -- the rows instead -- a box on every row was heavy, and the picker's own
                -- Class tab cannot stand in for it (see that toggle's note).
                gradGroup:AddWidget(row, 28)
            end

            -- ☠ NO RAMP-WIDE CLASS TOGGLE. One lived here briefly, governing only the top
            -- stop, and it quietly cost the per-stop control the old three-stage model
            -- had. The class choice belongs to each stop and now sits fused to that
            -- stop's swatch -- see the note on the pair above.
            --
            -- ⚠ The picker cannot absorb this either: its path rides Blizzard's
            -- SetupColorPickerAndShow hook and carries a COLOUR, with nowhere to put a
            -- boolean. And the two are not the same thing -- the flag resolves against
            -- each unit's own class per frame, while the picker's Class tab sets one
            -- fixed colour for everybody.

            -- Add drops a stop in the widest remaining gap, so repeated presses spread
            -- out instead of stacking against one edge. Its colour is sampled from the
            -- ramp at that point, so adding a stop never changes what is on screen --
            -- it only gives you a handle there.
            local footer = CreateFrame("Frame", nil, self.child)
            footer:SetSize(gradInner, 24)

            local addBtn = CreateFrame("Button", nil, footer, "BackdropTemplate")
            -- Same key the Color by Time editor's button uses, deliberately: two ramp
            -- editors that behave alike should not be worded differently.
            GUI:StyleButton(addBtn, { width = 100, height = 22, text = L["Add Color Stop"], fitText = true })
            addBtn:SetPoint("LEFT", footer, "LEFT", 0, 0)
            addBtn:SetScript("OnClick", function()
                local s = GradStops()
                local bestGap, bestAt = -1, nil
                for i = 1, #s - 1 do
                    local a = math.floor(tonumber(s[i].threshold) or 0)
                    local b = math.floor(tonumber(s[i + 1].threshold) or 0)
                    if (b - a) > bestGap then bestGap, bestAt = b - a, math.floor((a + b) / 2) end
                end
                if not bestAt or bestGap < 2 then return end   -- no room between neighbours
                local c = DF:GetHealthGradientColor(bestAt / 100, db, nil, prefix)
                table.insert(s, { threshold = bestAt,
                                  color = { r = c.r, g = c.g, b = c.b, a = 1 },
                                  useClass = false })
                GradRebuild()
            end)

            local resetBtn = CreateFrame("Button", nil, footer, "BackdropTemplate")
            GUI:StyleButton(resetBtn, { width = 100, height = 22, text = L["Reset"], fitText = true })
            resetBtn:SetPoint("LEFT", addBtn, "RIGHT", 6, 0)
            resetBtn:SetScript("OnClick", function()
                db[listKey] = GradDefaults()
                GradRebuild()
            end)

            gradGroup:AddWidget(footer, 28)
        end

        gradGroup.hideOn = hideOn
        AddToSection(gradGroup, nil, 1)
        end

        BuildGradientStopBox("healthColor",
            function(d) return d.healthColorMode ~= "PERCENT" end)

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
        
        -- ★ COLUMN 2, under Texture. Column 1 carries Color and then the Gradient editor,
        -- which is ~280 lines of widgets and expands further as stops are added — so with
        -- the gradient open, column 1 ran long while column 2 held Texture and nothing
        -- else, leaving that box stranded beside a wall of controls (Krathe, 2026-08-13).
        -- Background pairs naturally with Texture anyway: both are what the bar is drawn
        -- ON, against Color/Gradient which are what it is drawn IN.
        -- ⚠ When the gradient is hidden (healthColorMode ~= "PERCENT") this tips the other
        -- way — column 2 then holds two groups against column 1's one. That is the lesser
        -- imbalance, and the pending "gradient editor as a single-column box" rework
        -- changes the same balance, so the two want checking together.
        AddToSection(bgGroup, nil, 2)

        currentSection = nil
        AddSpace(GUI.Space.section, "both")
        
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

        -- ===== MISSING HEALTH GRADIENT (Column 1, conditional) =====
        -- ☠ The old Low/Medium/High stage groups that sat here (550px bar + three
        -- 280px groups) were editing missingHealthColorLow/Medium/High + Weight --
        -- keys the renderer stopped reading the moment the profile carried
        -- missingHealthColorStops, which every migrated profile does. The controls
        -- moved frames on no screen, and the preview bar above them read the stop
        -- list, so it did not respond either. Same stop-list box as the health bar.
        BuildGradientStopBox("missingHealthColor",
            function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT" end)

        currentSection = nil

        AddSpace(GUI.Space.section, "both")

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
        AddSpace(GUI.Space.block, "both")
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

        -- ===== SIZE GROUP (Column 1) =====
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Size"]), 40)
        sizeGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        local rbMatch = sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Match Health Bar Width/Height"], db, "resourceBarMatchWidth", function() DF:UpdateAllFrames() end), 30)
        -- ☠ THE SECOND SENTENCE IS THE ONE THAT WAS MISSING, AND IT COST A BUG REPORT.
        -- Matching pins the bar by its two ENDS, so the Anchor dropdown's left/right half
        -- stops applying: Top Left, Top and Top Right all render the same row, and the same
        -- for the bottom trio (Aphoex 3.2, "only 3 position anchors work"). The dropdown
        -- keeps all nine because they are all live the moment Match is off — the honest fix
        -- is to say so here rather than to silently drop six entries the user may be about
        -- to need. Also drops the old claim that "the Width slider greys out", which is only
        -- true for a horizontal bar; on a vertical one the matched dimension is the length,
        -- and Width / Length is exactly the control that owns it.
        rbMatch.tooltip = L["Keeps the resource bar the same length as the health bar it sits under, so it stays lined up when you resize the frame. The Width / Length slider greys out while this is on, and because the bar is pinned by its ends the Anchor only takes effect along the other axis."]
        local widthSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Width / Length"], 10, 200, 1, db, "resourceBarWidth", nil, function() DF:LightweightUpdatePowerBarSize() end, true), 55)
        widthSlider.disableOn = function(d) return d.resourceBarMatchWidth end
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, L["Height / Thickness"], 1, 20, 1, db, "resourceBarHeight", nil, function() DF:LightweightUpdatePowerBarSize() end, true), 55)
        Add(sizeGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 1) =====
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
        Add(positionGroup, nil, 1)
        
        -- ===== APPEARANCE GROUP (Column 2) — mirrors the Health Bar's Texture group:
        -- Texture, Orientation / Reverse Fill, and Smooth Bar Animation in one place. =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        appearanceGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        appearanceGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "resourceBarTexture", function() DF:UpdateAllFrames() end), 55)

        -- Keep Orientation (Horizontal/Vertical) and Reverse Fill as two explicit
        -- controls — clearer than a combined "Fill Direction" dropdown, where an
        -- option like "Bottom to Top" silently changes the orientation too.
        local orientOptions = { HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"] }
        appearanceGroup:AddWidget(GUI:CreateDropdown(self.child, L["Orientation"], orientOptions, db, "resourceBarOrientation", function() DF:UpdateAllFrames() end), 55)
        appearanceGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Fill Direction"], db, "resourceBarReverseFill", function() DF:UpdateAllFrames() end), 30)

        appearanceGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Smooth Bar Animation"], db, "resourceBarSmooth", function() DF:UpdateAllFrames() end), 30)
        Add(appearanceGroup, nil, 2)
        
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
        
        -- ===== BORDER GROUP (Column 2) =====
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
        Add(borderGroup, nil, 2)
        
        -- ===== FRAME LEVEL GROUP (Column 1) =====
        local frameLevelGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameLevelGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Level"]), 40)
        frameLevelGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
        frameLevelGroup:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "resourceBarFrameLevel", nil, function() DF:LightweightUpdateResourceBarFrameLevel() end, true)), 55)
        Add(frameLevelGroup, nil, 1)
        
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
        local rbColorMode = colorGroup:AddWidget(GUI:CreateDropdown(self.child, L["Color Mode"], RESOURCE_COLOR_MODES, db, "resourceBarColorMode", function()
            DF:RefreshAllVisibleFrames()
            self:RefreshStates()  -- re-evaluate the custom colour picker's hideOn
        end), 54)
        rbColorMode.tooltip = L["Power Type gives each resource its own game colour — blue mana, yellow energy, red rage. Class colours every bar by the unit's class instead, and Custom uses one fixed colour for everyone."]

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
        
        local levelSlider = AddToSection(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "absorbBarFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("absorb") end, true)), 55, 1)
        levelSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        currentSection = nil
        AddSpace(GUI.Space.section, "both")
        
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

        -- ⚠ healPredictionFrameLevel has existed and been honoured since the ladder work
        -- (Features/Auras.lua reads it, DF:ResolveHealPredictionBarLevel resolves it) but
        -- had NO control anywhere — the only key of the eighteen in Config that a user
        -- could not reach. Same shape and range as the absorb bar's, and FLOATING-only for
        -- the same reason: the bound modes take the ladder's slot, not a slider.
        local hpLevel = anchorGroup:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "healPredictionFrameLevel", nil, function() DF:UpdateAllFrames() end, true)), 55)
        hpLevel.disableOn = function(d) return not d.healPredictionEnabled end

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

    -- Reading order for the Auras sidebar, declared here and resolved at layout
    -- time (GUI:SetNavOrder). The seven pages are created across three files in a
    -- chain, so the order they land in is a build artefact -- this is the order a
    -- reader should meet them in, and the three captions say why that order.
    --
    -- ⚠ It matches the actual data flow. One page decides WHAT auras exist for the
    -- addon (the filter library); five pages decide WHERE something is drawn; the
    -- Aura Designer is a power tool on top. Listed alphabetically or by creation
    -- order, Aura Designer came SECOND, which read as a step everyone must take.
    --
    -- ⚠ Naming a page here does not create or show it: a hidden page stays hidden
    -- (UpdateTabLayout only places rows already in cat.children), and a page NOT
    -- named here still appears, at the end. So this cannot strand a page.
    if GUI.SetNavOrder then
        GUI:SetNavOrder("auras", {
            { caption = L["FILTERS"] },
            "auras_filterdesigner",
            { caption = L["DISPLAYS"] },
            "auras_buffs",
            "auras_debuffs",
            "auras_defensiveicon",
            "auras_missingbuffs",
            "auras_dispel",
            { caption = L["ADVANCED"] },
            "auras_auradesigner",
        })
    end

    -- Auras > Aura Filters (the merged page: pick filters AND edit their spells)
    --
    -- Keeps the FAMILIAR NAME while the page id stays "auras_filterdesigner". That is
    -- deliberate: every cross-link, Search entry and _fdSelect* entry point already
    -- targets that id, so relabelling costs nothing whereas renaming the id would mean
    -- chasing all of them. The old "auras_filters" page is gone -- its filter switches
    -- moved into this page's left-hand list, its ordering and duration controls onto
    -- the Buffs and Debuffs pages.
    --
    -- SECTION KEYS, spelled out rather than stemmed. Ownership is longest-prefix-wins
    -- (DF:SectionOwnsKey), so:
    --   * "buffFilterSelection" beats the Buffs page's broad "buff"
    --   * "debuffFilter" / "debuffBlacklist" beat the Debuffs page's broad "debuff"
    --   * the three scope keys are listed INDIVIDUALLY because the sort keys that just
    --     moved away (directBuffSortOrder, directDebuffSort*) share the "directBuff" /
    --     "directDebuff" stems. A stem here would drag them back, and this page's
    --     Copy/Reset would silently reach into the bar pages.
    -- "Filter Designer" — the label finally matches the page id it has always had.
    -- It was called Aura Filters while it did two jobs, one of which was choosing
    -- which filters each bar used; that job moved to the bars, so what is left is
    -- purely the place filters are DESIGNED. It is also buffs-only now, and "Aura
    -- Filters" implied it covered debuffs too.
    local pageFilterDesigner = CreateSubTab("auras", "auras_filterdesigner", L["Filter Designer"])
    BuildPage(pageFilterDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        -- ⚠ MIRRORED IN DF.SECTION_PREFIXES.auras_filterdesigner (GUI.lua) — change both.
        -- ☠ THIS PAGE OWNS NO PER-MODE KEYS ANY MORE, and its Copy/Sync/Reset list is
        -- deliberately EMPTY. It used to carry buffFilterSelection, debuffFilter*,
        -- debuffBlacklist and the directBuff*/directDebuff* switches; every one of
        -- those moved to the page whose controls now show it — buffFilterSelection
        -- and directBuff* to Buff Bar, the rest to Debuff Bar.
        --
        -- A page's Sync/Reset must own EXACTLY the keys it displays. Leaving these
        -- here would mean Reset Page on the filter library silently rewriting two
        -- other pages' settings, which is the bug class this addon has already been
        -- bitten by.
        --
        -- What this page edits instead is not per-mode at all: preset overrides are
        -- per PROFILE and custom filters are per ACCOUNT, so neither is something
        -- Copy to Raid or Sync with Raid can act on.
        -- ⚠ Still CALLED with an empty list, because the call is what registers this
        -- page in DF.SectionRegistry -- and it has to be registered as owning nothing,
        -- or SectionOwnsKey would fall through to another page's prefix and hand these
        -- keys back. The helper returns a zero-height placeholder for an empty list,
        -- so no dead Copy/Sync/Reset row is drawn.
        Add(CreateCopyButton(self.child, {}, L["Filter Designer"], "auras_filterdesigner"), 0, 2)
        if DF.BuildFilterDesignerPage then DF.BuildFilterDesignerPage(GUI, self, db) end

        -- See Also, after the page's own content. This page positions its panels
        -- absolutely and reports its height through an Add()ed spacer, so anything
        -- Add()ed afterwards lands below them -- which is where a footer belongs.
        --
        -- ⚠ This was REMOVED once, on the argument that the consumer chip row at the
        -- top of the page had replaced it and a second copy of the same links was
        -- redundant. That was wrong on two counts, and it is recorded here because
        -- the argument is tempting enough to be made again:
        --
        --   * Every other page under Auras carries a See Also. This page having none
        --     is not "one fewer duplicate", it is the one page that breaks the
        --     pattern -- which is exactly why the bar was added here in the first
        --     place.
        --   * The chips and this footer answer different questions. A chip says WHAT
        --     IS USING these filters right now, with a live count, and greys out when
        --     nothing is; See Also says WHERE ELSE YOU MIGHT GO, unconditionally. The
        --     Aura Designer chip reading "Not in use" is correct and is still a place
        --     you may want to visit.
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buff Bar"]},
            {pageId = "auras_debuffs", label = L["Debuff Bar"]},
            {pageId = "auras_defensiveicon", label = L["Defensive Icon"]},
            {pageId = "auras_auradesigner", label = L["Aura Designer"]},
        }), 30, "both")
    end)

    -- Auras > Aura Designer
    local pageAuraDesigner = CreateSubTab("auras", "auras_auradesigner", L["Aura Designer"])
    BuildPage(pageAuraDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        if DF.BuildAuraDesignerPage then
            DF.BuildAuraDesignerPage(GUI, self, db)
        end
    end)

    -- Auras > Aura Blacklist: RETIRED as a standalone page. The debuff blacklist
    -- now lives inside the Filter Designer (Debuffs > Blacklist) — one home for
    -- all per-spell aura control. Backend unchanged (AuraBlacklist/Config.lua +
    -- Features/Auras.lua applyDebuffBlacklist); stored data carries over.

    -- Auras > Buffs (combined Layout + Appearance with collapsible sections)
    -- "Buff Bar", not "Buffs": this page owns the bar's APPEARANCE and placement,
    -- while Aura Filters owns its CONTENTS. Two pages about one bar, and the old
    -- name made this the obvious place to look for buff filtering -- which it is not.
    local pageBuffs = CreateSubTab("auras", "auras_buffs", L["Buff Bar"])
    DF._SetupGUIPagesPart4(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
end