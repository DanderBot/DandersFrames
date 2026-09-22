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
                -- Raid sorting is applied by DF:ApplyHeaderSettings above, which routes
                -- to ApplyRaidGroupSorting / ApplyRaidFlatSorting. This branch stays so
                -- raid mode does not fall into the party resort below.
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
        -- refreshContent, so the banner never shows without a tone (the backdrop
        -- defaults to white until toned).
        combatBanner.refreshContent = UpdateCombatBanner
        Add(combatBanner, combatBanner.layoutHeight, "both")

        -- Initial update
        UpdateCombatBanner()
        
        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: five 280 boxes in two columns.
        -- MODERN is the Debuff Bar's collapsible-card design: one card per box,
        -- two settings per row, dim captions, Expand All / Collapse All at the
        -- top, and the two page columns classic has always drawn -- sorting itself
        -- down the left, the drag orders down the right:
        --
        --   column 1   Unit Frame Sorting (+ Self Position), FrameSort Integration
        --              (only with the FrameSort addon; header tick)
        --   column 2   "Priority"  Role Priority, Class Priority
        --
        -- ⚠ SELF POSITION MOVES INTO UNIT FRAME SORTING. It was the page's one lone
        -- control -- a one-dropdown box in classic, a control row after the popout
        -- sweep -- and it is the first level of the very order that card
        -- describes ("Self Position > Role > Class > Name"). Classic keeps its box.
        --
        -- ☠ ENABLE CUSTOM SORTING STAYS IN THE BODY of the first card, as Show
        -- Debuffs does on the Debuff Bar: it is the PAGE gate. Shut, that card's
        -- corner says Off while sorting is off; the two priority cards grey their
        -- headers with it. Use FrameSort Addon is its own card's on/off, so it moves
        -- into that card's header.
        --
        -- ⚠ NO PINS ON THIS PAGE. Every card decides what ORDER frames sort in,
        -- which is behaviour, not looks.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates } and, where a toggle is hoisted, `hoistToggle`.
        -- The classic branch mounts the SAME builder into the box it always built,
        -- which is what makes "classic is unchanged" structural rather than a
        -- promise -- test_sorting_page_builders.lua pins the inventory of each one
        -- against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery, which carries the card helper. nil in
        -- classic, which is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper and its two opt-ins, which every card
        -- here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ===== SELF POSITION'S VOCABULARY AND COMMIT, AT PAGE SCOPE ========
        -- Declared above the Unit Frame Sorting card, which carries the dropdown
        -- in modern; classic's own Self Position box, further down, reads the
        -- same two.
        local selfPosValues = {
            ["FIRST"] = L["Always First"],
            ["LAST"] = L["Always Last"],
            ["SORTED"] = L["Sorted with Group"],
            ["NORMAL"] = L["Sorted with Group"],
            _order = {"FIRST", "LAST", "SORTED"},
        }

        -- The dropdown's callback, under a name at page scope: both layouts drive
        -- it, and two copies of a body that repaints the combat banner is the
        -- kind of duplication that drifts one of them.
        local function ApplySelfPosition()
            TriggerSortForCurrentMode()
            UpdateCombatBanner()
        end

        -- ===== UNIT FRAME SORTING (a 280 box in classic, the first card in
        -- column 1 in modern) =====
        -- Verbatim, taking the group and parent it should build into: same
        -- factories, same L keys, same db keys, same slot heights, same hideOns.
        --
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER. In classic the box greys its
        -- own children while custom sorting is off; the card has to do the same,
        -- and one builder serving both is what stops the two drifting.
        local function BuildSortOptionsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Sort party members by role, class, and name.\n\nSort order: Self Position > Role > Class > Name"], 250), 60)

            local raidSortNote = group:AddWidget(GUI:CreateLabel(parent, L["Raid: Group layout sorts within each group.\nFlat grid layout sorts all players together."], 250), 35)
            raidSortNote.hideOn = function() return GUI.SelectedMode ~= "raid" end

            -- Built in both layouts: it is the PAGE gate, so no card hoists it
            -- (see the page note). The seam stays for any future caller.
            if not tools2.hoistToggle then
                local sortEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Custom Sorting"], db, "sortEnabled", function()
                    TriggerSortForCurrentMode()
                    UpdateCombatBanner()
                    self:RefreshStates()
                end), 30)
                sortEnable.keepEnabled = true
            end
            group.disableChildrenOn = DisableSortOptions

            local sortMeleeRanged = group:AddWidget(GUI:CreateCheckbox(parent, L["Separate Melee & Ranged DPS"], db, "sortSeparateMeleeRanged", function()
                TriggerSortForCurrentMode()
                -- The role list's SHAPE depends on this key -- four roles or
                -- three -- so it has to be told. `roleOrderWidget` is whichever
                -- instance the Role Priority builder made last (see its note);
                -- `reflowValues` is a belt for a caller that mounts more than one
                -- list (none does now: the priority cards have no pin).
                if roleOrderWidget and roleOrderWidget.Refresh then roleOrderWidget.Refresh() end
                if tools2.reflowValues then tools2.reflowValues() end
                UpdateCombatBanner()
                if tools2.refreshStates then tools2.refreshStates() end
            end), 30)
            sortMeleeRanged.hideOn = HideSortOptions

            local sortByClass = group:AddWidget(GUI:CreateCheckbox(parent, L["Sort by Class (within role)"], db, "sortByClass", function()
                TriggerSortForCurrentMode()
                if tools2.refreshStates then tools2.refreshStates() end
                UpdateCombatBanner()
            end), 30)
            sortByClass.hideOn = HideSortOptions

            local sortAlphaValues = {
                [false] = L["Off"],
                ["AZ"] = L["A to Z"],
                ["ZA"] = L["Z to A"],
                _order = {false, "AZ", "ZA"},
            }
            local sortAlpha = group:AddWidget(GUI:CreateDropdown(parent, L["Alphabetical (within class/role)"], sortAlphaValues, db, "sortAlphabetical", function()
                TriggerSortForCurrentMode()
                UpdateCombatBanner()
                if tools2.refreshStates then tools2.refreshStates() end
            end), 55)
            sortAlpha.hideOn = HideSortOptions
        end

        if classicLayout then
            local sortOptionsGroup = GUI:CreateSettingsGroup(self.child, 280)
            sortOptionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Unit Frame Sorting"]), 40)
            BuildSortOptionsGroup({
                group = sortOptionsGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(sortOptionsGroup, nil, 1)
        else
            -- The summary, per the page convention: at most four items, a fixed
            -- order, "\194\183" between them, WORDS localised and numbers raw,
            -- every read guarded because a profile mid-migration may be missing
            -- any of these keys.
            --
            -- It reads as the group's own blurb does -- "Self Position > Role >
            -- Class > Name" -- with the levels that are actually switched on.
            -- L["Role"] is unconditional because role order is what this sorts by
            -- whatever else is off, so a default profile still says something.
            -- Shut while sorting is off, the corner says Off instead.
            --
            -- ⚠ THE MELEE/RANGED SPLIT IS DELIBERATELY NOT HERE. It refines the
            -- Role entry rather than adding a level to the list, and there is no
            -- short word for it in the locale -- the checkbox's own label is a
            -- sentence. A summary is not worth inventing a string for.
            local function SortOptionsSummary(d)
                if not d then return "" end
                if not d.sortEnabled then return L["Off"] end
                local parts = { L["Role"] }
                if d.sortByClass then parts[#parts + 1] = L["Class"] end
                local alpha = d.sortAlphabetical
                if alpha == "AZ" then parts[#parts + 1] = L["A to Z"]
                elseif alpha == "ZA" then parts[#parts + 1] = L["Z to A"] end
                return table.concat(parts, " \194\183 ")
            end

            -- ☠ THE PAGE'S TWO BULK VERBS, at col "both", under the combat banner
            -- and above every card -- the Debuff Bar's placement.
            Add(tools.SectionControls(self.child), 24, "both")
            -- ☠ NO TICK: Enable Custom Sorting is the page gate and stays in the
            -- body, built by the builder exactly as classic builds it. No pin.
            local band = OpenSection(L["Unit Frame Sorting"], "sorting_unitframes", 1, SortOptionsSummary)
            BuildSortOptionsGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            -- ☠ SELF POSITION, THE PAGE'S LONE CONTROL, MOVED IN HERE (see the page
            -- note), at the foot of the order it heads. Classic's dropdown call,
            -- captioned with the box's own name -- "Position" alone, on a page
            -- about sorting, does not say WHOSE -- with the box's two gates: hidden
            -- under a FrameSort takeover, and greyed with the rest of this card by
            -- the builder's group gate while custom sorting is off.
            local selfPos = band:AddWidget(GUI:CreateDropdown(self.child, L["Self Position"], selfPosValues, db, "sortSelfPosition", ApplySelfPosition), 55)
            selfPos.hideOn = HideSortOptions
            CloseSection(band)
        end

        -- ===== FRAMESORT INTEGRATION GROUP (a 280 box in column 1 in classic, a
        -- card in column 1 in modern) =====
        -- Verbatim, taking the group and parent it should build into: same
        -- factories, same L keys, same db key, same callback, same slot heights.
        --
        -- The tick's commit, named so the in-body checkbox and the card's header
        -- tick run the same body.
        local function UseFrameSortChanged()
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
        end

        local function BuildFrameSortGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent, format(L["FrameSort addon detected. Enable to let FrameSort control frame ordering.\n\n%sExperimental:%s This feature is new and may not work perfectly in all scenarios. Please report any issues."], "|c" .. GUI:ToneHex("caution"), "|r"), 250), 70)
            -- Suppressed when the CARD's header carries this tick.
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Use FrameSort Addon"], db, "useFrameSort", UseFrameSortChanged), 30)
            end
        end

        -- ⚠ THE EXPERIMENTAL PARAGRAPH STAYS IN THE CARD'S BODY, at its 250 and
        -- its pinned slot: it is the one sentence on this page that must not be
        -- behind a hover, and a card flows it on a row of its own.
        if FrameSortApi then
            if classicLayout then
                local frameSortGroup = GUI:CreateSettingsGroup(self.child, 280)
                frameSortGroup:AddWidget(GUI:CreateHeader(self.child, L["FrameSort Integration"]), 40)
                BuildFrameSortGroup({ group = frameSortGroup, parent = self.child })
                Add(frameSortGroup, nil, 1)
            else
                -- ☠ USE FRAMESORT ADDON IS THE HEADER'S TICK; the builder skips
                -- its own (hoistToggle). Same key, label and commit. No pin.
                local band = OpenSection(L["FrameSort Integration"], "sorting_framesort", 1, nil, nil, nil, nil, {
                    db = db, key = "useFrameSort", label = L["Use FrameSort Addon"],
                    onChanged = UseFrameSortChanged,
                })
                BuildFrameSortGroup({ group = band, parent = self.child, hoistToggle = true })
                CloseSection(band)
            end
        end

        -- ===== SELF POSITION (a 280 box in column 1 in classic; in modern the
        -- last control of the Unit Frame Sorting card, above) =====
        if classicLayout then
            local selfPosGroup = GUI:CreateSettingsGroup(self.child, 280)
            selfPosGroup:AddWidget(GUI:CreateHeader(self.child, L["Self Position"]), 40)
            selfPosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Position"], selfPosValues, db, "sortSelfPosition", ApplySelfPosition), 55)
            selfPosGroup.hideOn = HideSortOptions
            selfPosGroup.disableChildrenOn = DisableSortOptions
            Add(selfPosGroup, nil, 1)
        else
            -- Modern: Self Position is the last control of Unit Frame Sorting.
        end

        -- ===== ROLE PRIORITY (a 280 box in classic, a card under "Priority" in
        -- column 2 in modern) =====
        -- ☠ THE WIDGET REFERENCE IS REBOUND ON EVERY BUILD, NOT CAPTURED ONCE.
        -- `roleOrderWidget` is read by the Separate Melee & Ranged callback,
        -- which has to repaint whichever role list the user can actually see.
        -- The upvalue is assigned INSIDE the builder so it always names the
        -- newest instance.
        local function BuildRolePriorityGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Drag to reorder. Top = first."], 250), 25)

            roleOrderWidget = GUI:CreateRoleOrderList(parent, db, "sortRoleOrder", function()
                TriggerSortForCurrentMode()
            end, "sortSeparateMeleeRanged")
            group:AddWidget(roleOrderWidget, 135)
            group.disableChildrenOn = DisableSortOptions
        end

        -- ===== CLASS PRIORITY (a 280 box in classic, a card under "Priority" in
        -- column 2 in modern) =====
        local function BuildClassPriorityGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Drag to reorder. Top = first."], 250), 25)

            local classOrderWidget = GUI:CreateClassOrderList(parent, db, "sortClassOrder", function()
                TriggerSortForCurrentMode()
            end)
            group:AddWidget(classOrderWidget, 320)
            group.disableChildrenOn = DisableSortOptions
        end

        if classicLayout then
            local rolePriorityGroup = GUI:CreateSettingsGroup(self.child, 280)
            rolePriorityGroup:AddWidget(GUI:CreateHeader(self.child, L["Role Priority"]), 40)
            BuildRolePriorityGroup({
                group = rolePriorityGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            rolePriorityGroup.hideOn = HideSortOptions
            Add(rolePriorityGroup, nil, 2)

            local classPriorityGroup = GUI:CreateSettingsGroup(self.child, 280)
            classPriorityGroup:AddWidget(GUI:CreateHeader(self.child, L["Class Priority"]), 40)
            BuildClassPriorityGroup({
                group = classPriorityGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            -- Hide under FrameSort takeover or when not sorting by class (variant
            -- gates); grey out when custom sorting is disabled (enable gate).
            classPriorityGroup.hideOn = function(d) return (d.useFrameSort and FrameSortApi) or not d.sortByClass end
            Add(classPriorityGroup, nil, 2)
        else
            -- The summaries: the top of each list, which is the one thing a drag
            -- order says in a line. Guarded reads, and NO invented words -- the
            -- role names are the locale's own and the class names are the
            -- client's, exactly as the two lists draw them. An order the page
            -- cannot read yields "", and a shut card is then just its title.
            --
            -- ⚠ THE ROLE WORD FOLLOWS THE SPLIT. With Separate Melee & Ranged
            -- off, the list folds MELEE and RANGED back into one DPS entry, so a
            -- summary reading the raw stored token would name a role the user
            -- cannot see in the list below it.
            local function RoleWord(role, separate)
                if role == "TANK" then return L["Tank"] end
                if role == "HEALER" then return L["Healer"] end
                if not separate then return L["DPS"] end
                if role == "MELEE" then return L["Melee DPS"] end
                if role == "RANGED" then return L["Ranged DPS"] end
                return L["DPS"]
            end

            local function RolePrioritySummary(d)
                if not d then return "" end
                local order = d.sortRoleOrder
                local top = type(order) == "table" and order[1] or nil
                if type(top) ~= "string" then return "" end
                return RoleWord(top, d.sortSeparateMeleeRanged) or ""
            end

            local function ClassPrioritySummary(d)
                if not d then return "" end
                local order = d.sortClassOrder
                local top = type(order) == "table" and order[1] or nil
                if type(top) ~= "string" then return "" end
                local names = LOCALIZED_CLASS_NAMES_MALE
                return (names and names[top]) or ""
            end

            -- The category header the two priority cards sit under, in column 2.
            -- It hides with them under a FrameSort takeover, so it is never a
            -- title left standing over nothing.
            local priorityHeader = GUI:CreateHeader(self.child, L["Priority"])
            priorityHeader.hideOn = HideSortOptions
            Add(priorityHeader, 40, 2)

            -- The box's own two gates, on the card: HIDDEN under a FrameSort
            -- takeover (header and band), the header GREYED while custom sorting
            -- is off -- the list itself greys through the builder's group gate.
            -- No pin: a drag order is behaviour.
            local band = OpenSection(L["Role Priority"], "sorting_rolepriority", 2, RolePrioritySummary,
                DisableSortOptions, HideSortOptions)
            BuildRolePriorityGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)

            -- Also hidden while Sort by Class is off -- classic's variant gate.
            local band = OpenSection(L["Class Priority"], "sorting_classpriority", 2, ClassPrioritySummary,
                DisableSortOptions, function(d) return (d.useFrameSort and FrameSortApi) or not d.sortByClass end)
            BuildClassPriorityGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_frame", label = L["Frame"]},
            {pageId = "general_labels", label = L["Group Labels"]},
        }), 30, "both")
    end)
    
    -- General > Nicknames (account-wide list; custom builder, no party/raid switch)
    local pageNicknames = CreateSubTab("general", "general_nicknames", L["Nicknames"])
    -- ONE BUILD, NOT ONE PER MODE (page.singleModeBuild -- see ONE RETAINED BUILD PER
    -- MODE in GUI/Panel.lua): rebuilt on every party/raid switch, as before.
    -- The list is ACCOUNT data redrawn by the page's own Refresh, which only the
    -- build on screen hears -- a retained other-mode build would show the old list.
    if pageNicknames then pageNicknames.singleModeBuild = true end
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
        --
        -- ===== COLOR PICKER (a 280 box in classic, a one-row band) =========
        -- Bound to the ACCOUNT-WIDE db, not the page's per-mode `db`. These render
        -- on both the Party and Raid tabs, and when they were per-mode the Raid copy
        -- was write-only -- the hooks only ever read party, so ticking it on Raid
        -- looked enabled and did nothing. One setting, one value, both tabs.
        local pickerDB = DF:GetGlobalDB()

        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery, taken unconditionally: nil in classic,
        -- which is what the `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- The page's one band: full-width and chromeless, because a feature row's
        -- popout docks outside the WINDOW and runs a beam back to the row, so a
        -- row that stopped 280px in would leave that beam crossing half the page.
        -- No header on it -- one row whose own label already says "Color Picker",
        -- which is the Sorting page's sortBand rule.
        local colorPickerBand
        if tools then
            colorPickerBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
        end

        -- The group's four widgets, verbatim, taking the group and parent they
        -- should build into -- the same factories, L keys, db keys and slot
        -- heights in both layouts.
        --
        -- ⚠ NO TOGGLE IS HOISTED. Neither tick means "am I doing anything": they
        -- are two INDEPENDENT overrides (this addon's pickers, and every other
        -- addon's), and either can be on without the other. A row that hoisted
        -- one would be claiming it speaks for the pair.
        local function BuildColorPickerGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateCheckbox(parent, L["Use DF Color Picker"], pickerDB, "colorPickerOverride", function()
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
            group:AddWidget(GUI:CreateLabel(parent, L["Replace Blizzard's color picker with the DandersFrames color picker for this addon."], 250), 40)

            group:AddWidget(GUI:CreateCheckbox(parent, L["Use DF Color Picker for All Addons"], pickerDB, "colorPickerGlobalOverride", function()
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
            group:AddWidget(GUI:CreateLabel(parent, L["Show the DF color picker when any addon opens a color picker."], 250), 30)
        end

        if classicLayout then
            local colorPickerGroup = GUI:CreateSettingsGroup(self.child, 280)
            colorPickerGroup:AddWidget(GUI:CreateHeader(self.child, L["Color Picker"]), 40)
            BuildColorPickerGroup({
                group = colorPickerGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(colorPickerGroup, nil, 1)
        else
            -- One word, and only for the state worth a word. Replacing every
            -- OTHER addon's picker is the setting a user will want confirmed at a
            -- glance, and L["All"] says it in a word the locale already ships.
            -- The this-addon-only state gets nothing: there is no existing word
            -- for it that is not either vague ("On", beside a row with no toggle)
            -- or a brand name standing in for a sentence -- and a summary is not
            -- worth inventing a string for. The kit still shows the label and the
            -- count badge, which is what an empty summary is for.
            local function ColorPickerSummary(d)
                if not d then return "" end
                if d.colorPickerGlobalOverride then return L["All"] end
                return ""
            end

            -- Two: the two ticks. The blurb under each is prose, not a setting.
            local COLOR_PICKER_COUNT = 2

            -- ☠ TWO TICKS, SO THE GROUP GOES ON THE PLATE. A click that opens a
            -- panel holding two checkboxes is a click that buys nothing, which is
            -- the whole argument for the hybrid page; the strip stops promising
            -- what is already on screen and offers to pin a second copy instead.
            -- The blurb under each tick rides along -- four children to the measure
            -- in CreatePopoutPageTools, two settings to the badge, and INLINE_MAX
            -- reads the first of those.
            local pickerMount, pickerContent = tools.PopoutContent(function(group, holder, reflow)
                BuildColorPickerGroup({ group = group, parent = holder, refreshStates = reflow })
            end, nil, { inline = true })
            local pickerRow = colorPickerBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Color Picker"],
                -- ⚠ THE GLOBAL TABLE, NOT tools.RowDB. Every other row on the
                -- sweep hands the kit the per-mode table because that is where
                -- its keys live; these two live in the account-wide db, and a row
                -- pointed at the per-mode one would read nil for both and print a
                -- summary about settings it is not showing.
                db      = function() return DF:GetGlobalDB() end,
                summary = ColorPickerSummary,
                count   = COLOR_PICKER_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = pickerMount,
                footerStrip = true,
            }))
            -- ☠ CLAIM THE KEYS, BUT NO MODIFIED TICK AND NO FOOTER -- and that is
            -- not an oversight to be tidied up by the next sweep.
            --
            -- ClaimKeys does two jobs. The one wanted here is the SEARCH row map:
            -- it records which row owns a setting, so a search hit on "Use DF
            -- Color Picker" can open the panel the control is behind. Without it
            -- the setting is findable in classic and unreachable in the popout
            -- layout.
            --
            -- The other job is the amber tick's key list, and that half is inert
            -- here on purpose. DF.Defaults (DandersFrames/Core/Defaults.lua)
            -- answers for DF.db.party / DF.db.raid / the stored raid baseline and
            -- nothing else, so:
            --   * WireModifiedTick would ask "is colorPickerOverride modified" of
            --     a table that has never held it -- the tick could never light.
            --   * WireFooter is worse than useless: Reset Group and Hold both
            --     write through that same engine, so they would stamp PER-MODE
            --     defaults for these two keys into DF.db[mode] -- inventing
            --     settings in the wrong table while the account-wide values the
            --     row is actually showing sat untouched.
            -- The correct home for a reset here is a global-db-aware engine that
            -- does not exist yet; until it does, no strip is the honest answer.
            tools.ClaimKeys(pickerRow, pickerContent)

            Add(colorPickerBand, nil, "both")
        end

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

        -- ===== Dispel Colours: the page's third palette ====================
        -- Account-wide per-dispel-type palette (DF.db.dispelColors), the single source of
        -- truth for both the debuff-icon border and the dispel overlay. Defaults ARE the
        -- game palette (GetGameDispelPalette, queried from AuraUtil), so an untouched
        -- palette matches the game exactly; the overlay always follows it, the icon when
        -- "Color by Dispel Type" is on. No None/Physical picker — that border is hidden on
        -- no-dispel-type auras and the overlay never fires on them. Editing re-drives frames.
        --
        -- ☠ RESOLVED AT PAGE SCOPE, ABOVE THE BUILDERS, exactly as the two tables
        -- above it are. The builders are CLOSURES now and a closure captures the
        -- upvalue that exists when it is CREATED, so anything a builder reads has
        -- to be declared before it. (The Fading page's three moved helpers, same
        -- rule.) Only the table LOOKUP moved; the per-type seeding stayed with the
        -- picker that reads it, inside the builder.
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

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: four 280 boxes -- Class Colors
        -- then Dispel Type Colors down column 1, Role Colors then the Color by
        -- Time section down column 2.
        --
        -- MODERN is the Debuff Bar's collapsible-card design: one card per box --
        -- the three palettes and the Color by Time editor -- two swatches per row
        -- inside a wide enough card, dim captions, Expand All / Collapse All at
        -- the top, and the two page columns classic has always used:
        --
        --   column 1   Class Colors, Dispel Type Colors
        --   column 2   Role Colors, Color by Time
        --
        -- ☠ EVERY KEY BEHIND THE THREE PALETTES IS A NON-PROFILE KEY.
        -- classColors / roleColors / dispelColors live at the ROOT of DF.db -- one
        -- set per profile, shared by party and raid -- and each group's own "Reset
        -- All to Default" button IS the reset story; it stays inside its card.
        --
        -- ⚠ NO SUMMARIES, AND NOTHING IS INVENTED TO MAKE ONE. A palette of
        -- swatches has no four of anything to name; a shut card is just its title.
        --
        -- ⚠ THE PALETTES ARE PINNABLE (they decide how frames look); Color by Time
        -- is NOT, because every structural edit in it rebuilds the page, which
        -- would close a pinned copy (see its own note).
        --
        -- ⚠ THE TWO CROSS-LINK ANCHORS SURVIVE ON THEIR OWN. "Dispel Type Colors"
        -- and "Color by Time" are reached from other pages through
        -- Search:ScrollToSection, which finds a page child by :GetText() -- and a
        -- card is a collapsible section, whose GetText is its title, and which the
        -- jump EXPANDS when the user had it shut.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates, popout }. The classic branch mounts the SAME
        -- builder into the box it always built, which is what makes "classic is
        -- unchanged" structural rather than a promise --
        -- test_colors_page_builders.lua pins the inventory of each one against the
        -- census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery, which carries the card helper. nil in
        -- classic, which is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper and its two opt-ins, which every card
        -- here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- Color by Time's column: column 2 in both layouts. (The popout layout
        -- moved it to column 1 once the palettes had left the columns for a
        -- full-width band; the cards are back in the columns, so it is back too.)
        local cbtColumn = 2

        -- ☠ WHAT A "RESET ALL TO DEFAULT" COSTS, AND WHY IT IS NOT THE SAME IN
        -- BOTH LAYOUTS. The button writes every swatch in its group behind the
        -- widgets' backs, so the swatches have to be repainted. Classic has always
        -- paid for that with a whole page rebuild (pageColors:Refresh), and it
        -- kept doing exactly that until the sweep below replaced it.
        --
        -- A pinned panel must not. A rebuild retires every widget on the page, and
        -- the shared helper's own prologue closes every open panel on the way in --
        -- so the panel the button was clicked in would slam shut under the user's
        -- hand. What the rebuild was actually buying is the swatch repaint, and
        -- that is precisely the value sweep: RefreshChildValues calls each
        -- control's `refreshValue`, which for a colour picker IS its UpdateSwatch
        -- (SettingsWidgets.lua). ReflowMounted(true) runs it on every mounted pane,
        -- including a pinned second one. (The Tooltips page's AnchorGateRefresh is
        -- the same shape for the same reason.)
        --
        -- ★ CLASSIC AND A CARD TAKE THE SAME SWEEP, over the one group the button
        -- sits in (every swatch it writes is a colour picker in that group); a card
        -- then sweeps any pinned copy of itself too. The page rebuild classic used
        -- to pay leaked the whole page per click; it is kept only as the fallback
        -- for a group without the sweep.
        local function RepaintSwatches(tools2)
            if tools2.popout then
                tools.ReflowMounted(true)
            elseif tools2.group and tools2.group.RefreshChildValues then
                tools2.group:RefreshChildValues()
                if tools then tools.ReflowMounted(true) end
            elseif pageColors and pageColors.Refresh then
                pageColors:Refresh()
            end
        end

        -- ===== CLASS COLORS (a 280 box in column 1 in classic, the first card in
        -- column 1 in modern) =====
        -- Verbatim, taking the group and parent it should build into: same
        -- factories, same L keys, same db keys, same callbacks, same slot heights.
        --
        -- ☠ THE THIRTEEN SEEDS STAY EXACTLY WHERE THEY WERE, inside the loop and
        -- ahead of the picker that reads each one. They are build-time writes to a
        -- non-profile table, and a card is built with the page, so they still land
        -- at the moment they always did. Moving them out would move WHEN a profile
        -- changes shape.
        --
        -- ☠ A CARD WITH NO TICK. There is no boolean here meaning "am I doing
        -- anything": a palette is always in force, and the group's only non-picker
        -- control is a reset button.
        local function BuildClassColorsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Customize class colors used throughout DandersFrames. Changes apply to health bars, name text, borders, and all other class-colored elements."], 260), 50)

            local resetAllBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
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
                -- Repaint the swatches through the value sweep (see RepaintSwatches).
                RepaintSwatches(tools2)
            end)
            group:AddWidget(resetAllBtn, 30)

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
                group:AddWidget(GUI:CreateColorPicker(parent, info.name, classColorsDB, token, false, function()
                    DF:RefreshAllVisibleFrames()
                end, function()
                    DF:RefreshAllVisibleFrames()
                end, true), 30)
            end
        end

        if classicLayout then
            -- ===== Column 1 =====
            local col1 = GUI:CreateSettingsGroup(self.child, 280)
            col1:AddWidget(GUI:CreateHeader(self.child, L["Class Colors"]), 40)
            BuildClassColorsGroup({
                group = col1,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(col1, nil, 1)
        else
            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Debuff Bar's placement: they act on cards in both columns.
            Add(tools.SectionControls(self.child), 24, "both")
            -- Column 1, pinnable, no summary (see the page note).
            local band = OpenSection(L["Class Colors"], "colors_class", 1, nil, nil, nil, BuildClassColorsGroup)
            BuildClassColorsGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== ROLE COLORS (a 280 box in column 2 in classic, the first card in
        -- column 2 in modern) =====
        -- Same shape as Class Colors, three swatches instead of thirteen, and the
        -- same three seeds staying inside the loop.
        local function BuildRoleColorsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Customize role colors used by any border whose Color Source is set to Role. Applies to Tank, Healer, and Damager assignments."], 260), 50)

            local roleResetBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            GUI:StyleButton(roleResetBtn, { width = 260, height = 24, text = L["Reset All to Default"] })
            roleResetBtn:SetScript("OnClick", function()
                for _, info in ipairs(ROLE_LIST) do
                    local d = ROLE_DEFAULTS[info.token]
                    if d then roleColorsDB[info.token] = { r = d.r, g = d.g, b = d.b, a = d.a } end
                end
                DF:RefreshAllVisibleFrames()
                RepaintSwatches(tools2)
            end)
            group:AddWidget(roleResetBtn, 30)

            for i = 1, #ROLE_LIST do
                local info = ROLE_LIST[i]
                if not roleColorsDB[info.token] then
                    local d = ROLE_DEFAULTS[info.token]
                    if d then roleColorsDB[info.token] = { r = d.r, g = d.g, b = d.b, a = d.a } end
                end
                group:AddWidget(GUI:CreateColorPicker(parent, info.name, roleColorsDB, info.token, false, function()
                    DF:RefreshAllVisibleFrames()
                end, function()
                    DF:RefreshAllVisibleFrames()
                end, true), 30)
            end
        end

        if classicLayout then
            -- ===== Column 2: Role Colors =====
            local col2 = GUI:CreateSettingsGroup(self.child, 280)
            col2:AddWidget(GUI:CreateHeader(self.child, L["Role Colors"]), 40)
            BuildRoleColorsGroup({
                group = col2,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(col2, nil, 2)
        else
            -- Column 2, pinnable, no summary.
            local band = OpenSection(L["Role Colors"], "colors_role", 2, nil, nil, nil, BuildRoleColorsGroup)
            BuildRoleColorsGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== DISPEL TYPE COLORS (a 280 box in column 1 in classic, the second
        -- card in column 1 in modern) =====
        -- The one palette whose commit is not a plain repaint: both callbacks stay
        -- exactly as they were, page-scope above, so the card and the box drive the
        -- same work.
        local function BuildDispelColorsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Colours for each dispel type, used by the dispel overlay and the debuff-icon border (when Color by Dispel Type is on). Reset restores the game's colours."], 260), 55)
            local dispelResetBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            GUI:StyleButton(dispelResetBtn, { width = 260, height = 24, text = L["Reset All to Default"] })
            dispelResetBtn:SetScript("OnClick", function()
                for _, info in ipairs(DISPEL_LIST) do
                    local d = dispelGamePalette[info.key]
                    if d then dispelColorsDB[info.key] = { r = d.r, g = d.g, b = d.b } end
                end
                DispelColorChanged()
                RepaintSwatches(tools2)
            end)
            group:AddWidget(dispelResetBtn, 30)
            for i = 1, #DISPEL_LIST do
                local info = DISPEL_LIST[i]
                if type(dispelColorsDB[info.key]) ~= "table" then
                    local d = dispelGamePalette[info.key]
                    if d then dispelColorsDB[info.key] = { r = d.r, g = d.g, b = d.b } end
                end
                group:AddWidget(GUI:CreateColorPicker(parent, info.name, dispelColorsDB, info.key, false, DispelColorChanged, DispelColorLive, true), 30)
            end
        end

        if classicLayout then
            local dispelCol = GUI:CreateSettingsGroup(self.child, 280)
            dispelCol:AddWidget(GUI:CreateHeader(self.child, L["Dispel Type Colors"]), 40)
            BuildDispelColorsGroup({
                group = dispelCol,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(dispelCol, nil, 1)
        else
            -- Column 1 under Class Colors, pinnable, no summary. Its title is the
            -- cross-link anchor the debuff Border and Dispel Overlay pages jump to
            -- (see the page note) -- keep it in step with theirs.
            local band = OpenSection(L["Dispel Type Colors"], "colors_dispel", 1, nil, nil, nil, BuildDispelColorsGroup)
            BuildDispelColorsGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== Color by Time Remaining -- a collapsible section over a 280 box in
        -- classic, a card in column 2 in modern =====
        -- ☠ THE ONE CARD ON THIS PAGE WITHOUT A PIN, and it was the one group the
        -- popout layout never turned into a row. The reasons are structural rather
        -- than taste:
        --
        --   1. IT REBUILDS THE PAGE ON EVERY STRUCTURAL EDIT. Adding a stop,
        --      removing one, committing a threshold and flipping the s/% tab all
        --      end in pageColors:Refresh() -- and they have to, because each one
        --      changes which WIDGETS the editor has (a stop row appears or goes,
        --      and every remaining range label is recomputed from its neighbours).
        --      Inside a pinned panel that is fatal: a rebuild retires the panel,
        --      and the shared helper's prologue closes every open panel on the way
        --      in, so the editor would slam its own panel shut on each + click. The
        --      palettes above dodge this because their reset only moves VALUES,
        --      which the pane's value sweep repaints in place; there is no such
        --      sweep for "this group now has a different list of children", and
        --      hand-rolling one here would mean reimplementing the page builder's
        --      own widget-retire loop inside a settings page. (Pet Frames keeps
        --      Layout Mode inline for exactly this reason.)
        --
        --   2. ITS TITLE IS A CROSS-LINK ANCHOR, and a live one: every aura page
        --      and the Aura Designer reach it through UI:CreateColorsPageLink ->
        --      LinkToSetting{ page = "display_classcolors", section = the Color by
        --      Time title }. Search:ScrollToSection resolves that against the page's
        --      OWN children, and a CollapsibleSection is the one target it handles
        --      specially -- it EXPANDS the section if the user had it closed, then
        --      flashes the content rather than the 28px bar. A card IS such a
        --      section, so the anchor keeps all of that in modern too.
        --
        --   3. IT IS AN EDITOR, NOT A GROUP OF SETTINGS. A row's contract is a
        --      label, a count of controls and a one-line summary; this box holds
        --      unit tabs, a preview strip, a variable list of stops and a "how this
        --      renders" legend. There is no honest count and no four-item summary
        --      to write.
        --
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

        -- ⚠ CLASSIC'S 280 BOX, OR MODERN'S CARD -- an expression, not an arm, so
        -- nothing below has to know which layout it is building into. The card's
        -- band re-sizes its rows on every layout pass; the 260px rows inside were
        -- laid out for the box and sit left-aligned in a wider card.
        local cbtGroup = classicLayout
            and GUI:CreateSettingsGroup(self.child, 280)
            or OpenSection(L["Color by Time"], "colors_bytime", cbtColumn)

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
        -- as a tooltip on the value box.
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
        if classicLayout then
            Add(cbtGroup, nil, cbtColumn)
            if cbtSection then cbtSection:RegisterChild(cbtGroup) end
        else
            CloseSection(cbtGroup)
        end
        end   -- BuildSection

        -- One column, not "both": the header belongs over the box it owns rather than
        -- spanning the page (in classic, column 1 holds the dispel palette, which it
        -- does not own). Width matches the box so the rule under the title lines up
        -- with it. ☠ CLASSIC'S ONLY: in modern the card opened in BuildSection is the
        -- section.
        cbtSection = classicLayout
            and Add(GUI:CreateCollapsibleSection(self.child, L["Color by Time"], true, 280), 36, cbtColumn)
            or nil
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
        
        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: three collapsible sections over
        -- seven 280 boxes -- Color (col 1), Texture (col 2), the health gradient
        -- editor (col 1) and Background (col 2) under "Health Bar"; the settings
        -- box (col 1) and its own gradient editor (col 1) under "Missing Health";
        -- and one settings box (col 1) under "Reduced Max Health".
        --
        -- MODERN is the Debuff Bar's collapsible-card design: one card per box,
        -- the two gradient editors included, two settings per row, dim captions,
        -- Expand All / Collapse All at the top and TWO page columns when the
        -- window is wide -- what the bar is drawn IN on the left, what it is drawn
        -- ON and the overlay on the right:
        --
        --   column 1   Color, Gradient (health colour mode Health Gradient only),
        --              Missing Health, Gradient (missing health's, same rule)
        --   column 2   Texture, Background, Reduced Max Health (header tick)
        --
        -- The cards are ADDED in classic's reading order (Color, Texture, Gradient,
        -- Background, ...), which is also the order the one-column fold reads.
        --
        -- ☠ THE THREE FULL-WIDTH SECTIONS ARE CLASSIC'S ONLY, and so are the
        -- spacers between them. In modern each card IS a section -- it folds and
        -- persists its fold under its own stable key -- and a full-width section
        -- or spacer is a "both" widget, a SYNC POINT that would end both columns
        -- and stack the page back into one. Built through expressions rather than
        -- arms, the gradient box's idiom below, so classic's arms stay what they
        -- were.
        --
        -- ⚠ THE TWO GRADIENT EDITORS ARE CARDS WITHOUT A PIN. Adding, removing or
        -- moving a stop REBUILDS THE PAGE (see GradRebuild), and a pinned copy
        -- would be closed by the rebuild it caused. Their cards hide with their
        -- colour mode, header and band together.
        --
        -- ⚠ REDUCED MAX HEALTH'S ENABLE IS THE CARD'S HEADER TICK (hoistToggle),
        -- one checkbox per setting; the group gate inside the builder still greys
        -- the four controls under it.
        --
        -- Every box's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates } and, where a toggle is hoisted, `hoistToggle`.
        -- The classic branch mounts the SAME builder into the box it always
        -- built, which is what makes "classic is unchanged" structural rather
        -- than a promise -- test_healthbar_page_builders.lua pins the inventory
        -- of each one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery, which carries the card helper. nil in
        -- classic, which is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper and its two opt-ins, which every card
        -- here takes. ⚠ Declared ABOVE BuildGradientStopBox, which opens its card
        -- through it -- a closure captures the upvalue that exists when it is made.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ===== THE PAGE'S DROPDOWN VOCABULARY, AT PAGE SCOPE ==============
        -- The cards print the chosen value as their SUMMARY, and a summary is
        -- written OUTSIDE the group's builder -- so the word has to come out of
        -- the same table the dropdown offers, or a card could say one thing while
        -- the control behind it says another. (The Tooltips page hoisted its five
        -- Anchor To tables for exactly this reason.)
        local colorModes = { CLASS= L["Class Color"], CUSTOM= L["Custom Color"], PERCENT= L["Health Gradient"] }
        local orientOptions = {
            HORIZONTAL= L["Left to Right"], HORIZONTAL_INV= L["Right to Left"],
            VERTICAL= L["Bottom to Top"], VERTICAL_INV= L["Top to Bottom"],
        }
        local bgModes = { CUSTOM= L["Custom Color"], CLASS= L["Class Color"] }
        local bgFillModes = { BACKGROUND= L["Background Only"], MISSING_HEALTH= L["Missing Health Only"], BOTH= L["Both"] }
        local missingHealthColorModes = { CUSTOM= L["Custom Color"], CLASS= L["Class Color"], PERCENT= L["Health Gradient"] }
        local reducedBlendOpts = { BLEND = L["Blend"], ADD = L["Add"], MOD = L["Modulate"] }

        -- The texture's display NAME, from the addon's own media resolver -- the
        -- one GUI:CreateTextureDropdown prints on its own button, so a card and
        -- the control behind it cannot disagree. (Pet Frames' Appearance row
        -- names its texture through this same function, for the same reason.)
        local function TextureName(path)
            local name = DF.GetTextureNameFromPath and DF:GetTextureNameFromPath(path)
            if type(name) == "string" and name ~= "" then return name end
            return nil
        end

        -- ☠ THE FOUR MODE DROPDOWNS RE-GATE THINGS ON BOTH SIDES OF THE PANE.
        -- Picking a colour mode hides or shows controls in its OWN group and the
        -- gradient editor that stays out on the page. Classic paid for that with
        -- self:RefreshStates() -- the page's own hideOn/disableOn pass, NOT
        -- GUI:RefreshCurrentPage -- so there is no rebuild to unpick here, which
        -- is why this page needs no AnchorGateRefresh-style branch.
        --
        -- tools2.refreshStates IS that same call in classic and on a card (both
        -- hand it `function() self:RefreshStates() end`, and the page pass is what
        -- the gradient cards' hideOn rides on) and, in a pinned panel, ReflowPane
        -- followed by the page's own RefreshStates. One call, every job.

        -- ===== HEALTH BAR SECTION =====
        -- ☠ CLASSIC'S ONLY -- in modern each card is its own section (see the
        -- page note). An expression rather than an arm, so classic's arms stay
        -- exactly what they were.
        local healthBarSection = classicLayout
            and Add(GUI:CreateCollapsibleSection(self.child, L["Health Bar"], true), 36, "both")
            or nil
        currentSection = healthBarSection

        -- ===== COLOR (a 280 box in column 1 in classic, the first card in
        -- column 1 in modern) =====
        local function BuildHealthColorGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateDropdown(parent, L["Color Mode"], colorModes, db, "healthColorMode", function()
                tools2.refreshStates()
                DF:UpdateColorCurve()
                -- Refresh health colors on all frames (same as alpha slider)
                DF:RefreshAllVisibleFrames()
            end), 55)

            local classAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Health Bar Alpha"], 0, 1, 0.05, db, "classColorAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            classAlpha.hideOn = function(d) return d.healthColorMode ~= "CLASS" and d.healthColorMode ~= "PERCENT" end

            local customColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Custom Health Color"], db, "healthColor", true, nil, function() DF:LightweightUpdateHealthColor() end, true), 35)
            customColor.hideOn = function(d) return d.healthColorMode ~= "CUSTOM" end
        end

        -- The mode in the dropdown's own words, and the alpha ONLY when it is
        -- doing something -- a card reading "Alpha 1.00" on every default profile
        -- is noise (the Border row's rule). The alpha is absent under Custom
        -- Color for a second reason: its slider is hidden there.
        local function HealthColorSummary(d)
            if not d then return "" end
            local parts = {}
            local mode = colorModes[d.healthColorMode]
            if mode then parts[#parts + 1] = mode end
            if d.healthColorMode ~= "CUSTOM" then
                local a = tonumber(d.classColorAlpha)
                if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            end
            return table.concat(parts, " \194\183 ")
        end

        -- ===== TEXTURE (a 280 box in column 2 in classic, the first card in
        -- column 2 in modern) =====
        local function BuildHealthTextureGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "healthTexture"), 55)
            group:AddWidget(GUI:CreateDropdown(parent, L["Fill Direction"], orientOptions, db, "healthOrientation", function() DF:UpdateAllFrames() end), 55)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Smooth Bar Animation"], db, "smoothBars", function() DF:UpdateAllFrames() end), 30)
        end

        -- The texture's name, and the fill direction only when it is NOT the
        -- plain left-to-right -- the same discipline the Tooltips hover rows use
        -- for their in-combat pick, which is named only when it is not Always.
        local function HealthTextureSummary(d)
            if not d then return "" end
            local parts = {}
            local name = TextureName(d.healthTexture)
            if name then parts[#parts + 1] = name end
            if d.healthOrientation and d.healthOrientation ~= "HORIZONTAL" then
                local dir = orientOptions[d.healthOrientation]
                if dir then parts[#parts + 1] = dir end
            end
            return table.concat(parts, " \194\183 ")
        end

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
        --
        -- ★ AND IT STAYS INLINE IN BOTH LAYOUTS -- the Color by Time precedent,
        -- for the same structural reason rather than for taste. GradRebuild ends
        -- in pageHealthBar:Refresh(), a full PAGE REBUILD, and it has to: adding
        -- a stop, removing one and committing a threshold each change which
        -- WIDGETS the editor has, and every remaining stepper's bounds are
        -- recomputed from its neighbours. Inside a pane that is fatal -- a
        -- rebuild retires the pane, and CreatePopoutPageTools' own prologue
        -- closes every open panel on the way in, so the editor would slam its own
        -- panel shut on each + click. There is no rebuild-one-pane verb, and
        -- hand-rolling one here means reimplementing the page builder's widget
        -- retire loop inside a settings page.
        --
        -- ☠ IN MODERN IT IS A CARD OF ITS OWN, in column 1 under the card it
        -- belongs to, and its band IS the group every row below goes into -- so
        -- it takes no header (the card's title says "Gradient") and no pin (a
        -- pinned copy would be closed by the very rebuild its + button causes).
        -- Every row, the bar and the footer are prose-shaped (no bound value), so
        -- the card's two-per-row flow gives each a row of its own; and the band
        -- re-sizes its children on every layout pass, so a stop row follows the
        -- card's width when the window folds or a resize drags it.
        --
        -- ⚠ A REBUILD FROM HERE CLOSES ANY PINNED PANEL, and that is accepted
        -- rather than fixed, as it was for the popout rows before the cards: the
        -- panels hold the colour/texture cards, not the ramp.
        local function BuildGradientStopBox(prefix, hideOn)
        local listKey = prefix .. "Stops"
        -- ⚠ THE TWO CONSTRUCTIONS AS AN EXPRESSION, NOT AN `if classicLayout then`
        -- ARM. This builder is declared ABOVE the section's own layout arms and
        -- inside the page builder's indent, so a second `if classicLayout then ...
        -- else` at that indent here is one the section's own arm-locators would
        -- find first. Classic builds its 280 box; modern opens a card in column 1
        -- under a stable key of its own, hidden with its colour mode.
        local gradGroup = classicLayout
            and GUI:CreateSettingsGroup(self.child, 280)
            or OpenSection(L["Gradient"], (prefix == "healthColor") and "health_gradient" or "health_missinggradient",
                1, nil, nil, hideOn)
        -- The card's title already says Gradient; only classic's box needs one.
        if classicLayout then gradGroup:AddWidget(GUI:CreateHeader(self.child, L["Gradient"]), 40) end
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
        -- Column 1 in classic, exactly where it always was; in modern the card
        -- puts its band in after its last row, in its own column.
        if classicLayout then AddToSection(gradGroup, nil, 1) else CloseSection(gradGroup) end
        end

        -- ===== BACKGROUND (a 280 box in column 2 in classic, the second card
        -- in column 2 in modern) =====
        local function BuildHealthBackgroundGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateDropdown(parent, L["Background Mode"], bgModes, db, "backgroundColorMode", function()
                tools2.refreshStates()
                DF:LightweightUpdateBackgroundColor()
            end), 55)

            local bgTextureOptions = DF:GetTextureList(true)
            group:AddWidget(GUI:CreateTextureDropdown(parent, L["Background Texture"], db, "backgroundTexture", function()
                DF:LightweightUpdateBackgroundColor()
            end, bgTextureOptions), 55)

            local bgColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], db, "backgroundColor", true, nil, function() DF:LightweightUpdateBackgroundColor() end, true), 35)
            bgColor.hideOn = function(d) return d.backgroundColorMode ~= "CUSTOM" end

            local bgClassAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Background Alpha"], 0, 1, 0.05, db, "backgroundClassAlpha", nil, function() DF:LightweightUpdateBackgroundColor() end, true), 55)
            bgClassAlpha.hideOn = function(d) return d.backgroundColorMode ~= "CLASS" end
        end

        -- The colour source in the dropdown's own words, then the texture's name
        -- through the same resolver the Texture card uses.
        local function HealthBackgroundSummary(d)
            if not d then return "" end
            local parts = {}
            local mode = bgModes[d.backgroundColorMode]
            if mode then parts[#parts + 1] = mode end
            local name = TextureName(d.backgroundTexture)
            if name then parts[#parts + 1] = name end
            return table.concat(parts, " \194\183 ")
        end

        -- ===== THE HEALTH BAR SECTION'S MOUNT ==============================
        -- ☠ ONE if/else FOR THE WHOLE SECTION, rather than the per-group arm
        -- most pages use, because both layouts add in the same interleaved
        -- order -- Color (1), Texture (2), the gradient editor (1), Background
        -- (2) -- and classic's arm has always read as one block. The cards follow
        -- the same order, which is the order the one-column fold reads.
        --
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
        -- ⚠ MODERN KEEPS THE SAME SPLIT for the same reason, and balances it
        -- against the rest of the page: Missing Health (and its gradient) join
        -- column 1, Reduced Max Health joins column 2.
        local function HealthGradientHiddenOn(d) return d.healthColorMode ~= "PERCENT" end

        if classicLayout then
            local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
            colorGroup:AddWidget(GUI:CreateHeader(self.child, L["Color"]), 40)
            BuildHealthColorGroup({
                group = colorGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            AddToSection(colorGroup, nil, 1)

            local textureGroup = GUI:CreateSettingsGroup(self.child, 280)
            textureGroup:AddWidget(GUI:CreateHeader(self.child, L["Texture"]), 40)
            BuildHealthTextureGroup({
                group = textureGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            AddToSection(textureGroup, nil, 2)

            BuildGradientStopBox("healthColor", HealthGradientHiddenOn)

            local bgGroup = GUI:CreateSettingsGroup(self.child, 280)
            bgGroup:AddWidget(GUI:CreateHeader(self.child, L["Background"]), 40)
            BuildHealthBackgroundGroup({
                group = bgGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            AddToSection(bgGroup, nil, 2)
        else
            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Debuff Bar's placement: they act on cards in both columns.
            Add(tools.SectionControls(self.child), 24, "both")

            -- Pins on all three: they are what the bar is drawn IN and ON.
            local band = OpenSection(L["Color"], "health_color", 1, HealthColorSummary, nil, nil,
                BuildHealthColorGroup)
            BuildHealthColorGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)

            local band = OpenSection(L["Texture"], "health_texture", 2, HealthTextureSummary, nil, nil,
                BuildHealthTextureGroup)
            BuildHealthTextureGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)

            -- The Gradient card, column 1 under Color (see BuildGradientStopBox).
            BuildGradientStopBox("healthColor", HealthGradientHiddenOn)

            local band = OpenSection(L["Background"], "health_background", 2, HealthBackgroundSummary, nil, nil,
                BuildHealthBackgroundGroup)
            BuildHealthBackgroundGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        currentSection = nil
        -- ☠ CLASSIC'S ONLY: a "both" spacer would end both card columns.
        if classicLayout then AddSpace(GUI.Space.section, "both") end

        -- ===== MISSING HEALTH SECTION =====
        -- ☠ CLASSIC'S ONLY, as the Health Bar section above.
        local missingSection = classicLayout
            and Add(GUI:CreateCollapsibleSection(self.child, L["Missing Health"], true), 36, "both")
            or nil
        currentSection = missingSection
        
        -- ===== MISSING HEALTH (a 280 box in column 1 in classic, a card in
        -- column 1 in modern) =====
        local function BuildMissingHealthGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local bgFillMode = group:AddWidget(GUI:CreateDropdown(parent, L["Background Fill"], bgFillModes, db, "backgroundMode", function()
                tools2.refreshStates()
                DF:UpdateAllFrames()
            end), 55)
            bgFillMode.tooltip = L["Background Only: Normal solid background\nMissing Health Only: Shows colored bar where health is missing\nBoth: Shows both"]

            local missingHealthTextureOptions = DF:GetTextureList(false)
            local missingHealthTexture = group:AddWidget(GUI:CreateTextureDropdown(parent, L["Missing Health Texture"], db, "missingHealthTexture", function()
                DF:UpdateAllFrames()
            end, missingHealthTextureOptions), 55)
            missingHealthTexture.hideOn = function(d) return d.backgroundMode == "BACKGROUND" end

            local missingHealthColorMode = group:AddWidget(GUI:CreateDropdown(parent, L["Color Mode"], missingHealthColorModes, db, "missingHealthColorMode", function()
                tools2.refreshStates()
                DF:UpdateColorCurve()
                DF:UpdateAllFrames()
            end), 55)
            missingHealthColorMode.hideOn = function(d) return d.backgroundMode == "BACKGROUND" end

            local missingHealthColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Missing Health Color"], db, "missingHealthColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
            missingHealthColor.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "CUSTOM" end

            local missingHealthClassAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Class Color Alpha"], 0, 1, 0.05, db, "missingHealthClassAlpha", nil, function() DF:UpdateAllFrames() end, true), 55)
            missingHealthClassAlpha.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "CLASS" end

            local missingHealthGradientAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Gradient Color Alpha"], 0, 1, 0.05, db, "missingHealthGradientAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            missingHealthGradientAlpha.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT" end
        end

        -- The fill mode, then the colour source -- and the second only when the
        -- fill is not Background Only, because everything below that pick is
        -- HIDDEN there and a summary must not describe controls the card is not
        -- showing.
        local function MissingHealthSummary(d)
            if not d then return "" end
            local parts = {}
            local fill = bgFillModes[d.backgroundMode]
            if fill then parts[#parts + 1] = fill end
            if d.backgroundMode ~= "BACKGROUND" then
                local mode = missingHealthColorModes[d.missingHealthColorMode]
                if mode then parts[#parts + 1] = mode end
            end
            return table.concat(parts, " \194\183 ")
        end

        -- ===== MISSING HEALTH GRADIENT (Column 1, conditional) =====
        -- ☠ The old Low/Medium/High stage groups that sat here (550px bar + three
        -- 280px groups) were editing missingHealthColorLow/Medium/High + Weight --
        -- keys the renderer stopped reading the moment the profile carried
        -- missingHealthColorStops, which every migrated profile does. The controls
        -- moved frames on no screen, and the preview bar above them read the stop
        -- list, so it did not respond either. Same stop-list box as the health bar.
        local function MissingGradientHiddenOn(d)
            return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "PERCENT"
        end

        -- One if/else for the section, for the reason the Health Bar section has
        -- one: the settings and the gradient editor go in as a pair, in order.
        if classicLayout then
            local missingGroup = GUI:CreateSettingsGroup(self.child, 280)
            missingGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
            BuildMissingHealthGroup({
                group = missingGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            AddToSection(missingGroup, nil, 1)

            BuildGradientStopBox("missingHealthColor", MissingGradientHiddenOn)
        else
            -- Column 1, pinnable. No tick: backgroundMode is a three-way pick,
            -- not a boolean, so nothing means "am I doing anything at all".
            local band = OpenSection(L["Missing Health"], "health_missing", 1, MissingHealthSummary, nil, nil,
                BuildMissingHealthGroup)
            BuildMissingHealthGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)

            -- Its Gradient card, column 1 directly under it.
            BuildGradientStopBox("missingHealthColor", MissingGradientHiddenOn)
        end

        currentSection = nil

        -- ☠ CLASSIC'S ONLY, as the spacer and the sections above.
        if classicLayout then AddSpace(GUI.Space.section, "both") end

        -- ===== REDUCED MAX HEALTH SECTION =====
        local reducedSection = classicLayout
            and Add(GUI:CreateCollapsibleSection(self.child, L["Reduced Max Health"], true), 36, "both")
            or nil
        currentSection = reducedSection

        -- ===== REDUCED MAX HEALTH (a 280 box in column 1 in classic, a card in
        -- column 2 in modern) =====
        --
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER. In classic the box greys its
        -- own children while the overlay is off; the card has to do the same, and
        -- one builder serving both is what stops the two drifting.
        local function BuildReducedMaxHealthGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the CARD's header carries this tick. Still built in
            -- classic, where it is the group's only on/off control.
            if not tools2.hoistToggle then
                local reducedEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable"], db, "reducedMaxHealthEnabled", function() tools2.refreshStates() DF:UpdateAllFrames() end), 30)
                reducedEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.reducedMaxHealthEnabled end

            group:AddWidget(GUI:CreateCheckbox(parent, L["Clip Health Bar"], db, "reducedMaxHealthClipHealthBar", function() DF:UpdateAllFrames() end), 30)
            group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "reducedMaxHealthTexture", function() DF:UpdateAllFrames() end), 55)
            group:AddWidget(GUI:CreateColorPicker(parent, L["Bar Color"], db, "reducedMaxHealthColor", true, nil, function() DF:LightweightUpdateReducedMaxHealthColor() end, true), 35)
            group:AddWidget(GUI:CreateDropdown(parent, L["Blend Mode"], reducedBlendOpts, db, "reducedMaxHealthBlendMode", function() DF:UpdateAllFrames() end), 55)
        end

        -- The overlay's texture, and the blend only when it is NOT the plain
        -- Blend -- the Texture card's own rule for a value that is the default on
        -- every profile.
        local function ReducedMaxHealthSummary(d)
            if not d then return "" end
            local parts = {}
            local name = TextureName(d.reducedMaxHealthTexture)
            if name then parts[#parts + 1] = name end
            if d.reducedMaxHealthBlendMode and d.reducedMaxHealthBlendMode ~= "BLEND" then
                local blend = reducedBlendOpts[d.reducedMaxHealthBlendMode]
                if blend then parts[#parts + 1] = blend end
            end
            return table.concat(parts, " \194\183 ")
        end

        if classicLayout then
            local reducedGroup = GUI:CreateSettingsGroup(self.child, 280)
            reducedGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
            BuildReducedMaxHealthGroup({
                group = reducedGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            AddToSection(reducedGroup, nil, 1)
        else
            -- ☠ ENABLE IS THE HEADER'S TICK; the builder skips its own
            -- (hoistToggle). Same key and label, and the commit is what the
            -- suppressed checkbox ran plus the state pass that re-greys the four
            -- controls under it -- never a page rebuild. A pin: the overlay's
            -- texture, colour and blend are how it LOOKS.
            local band = OpenSection(L["Reduced Max Health"], "health_reduced", 2, ReducedMaxHealthSummary, nil, nil,
                BuildReducedMaxHealthGroup, {
                    db = db, key = "reducedMaxHealthEnabled", label = L["Enable"],
                    onChanged = function()
                        DF:UpdateAllFrames()
                        self:RefreshStates()
                        tools.ReflowMounted()
                    end,
                })
            BuildReducedMaxHealthGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

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
        Add(CreateCopyButton(self.child, {"resourceBar"}, L["Resource Bar"], "bars_resource"), 25, 2)

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: nine 280 boxes -- Settings, Class
        -- Filter, Size and Position down column 1; Appearance, Background and
        -- Border down column 2; Frame Level back in column 1; Resource Colors last
        -- in column 2.
        --
        -- MODERN is the Debuff Bar's collapsible-card design: one card per box,
        -- two settings per row, dim captions, Expand All / Collapse All at the top,
        -- and two page columns -- what the bar DOES on the left, how it LOOKS on
        -- the right -- under the three category headers the popout bands had:
        --
        --   column 1   "General"  Resource Bar Settings, Class Filter
        --              "Layout"   Size, Position (+ Frame Level)
        --   column 2   "Style"    Appearance, Background (header tick), Border
        --                         (header tick), Resource Colors
        --
        -- ⚠ FRAME LEVEL MOVES INTO POSITION. It was the page's one lone control --
        -- a one-slider box in classic, a control row after the popout sweep -- and
        -- where the bar sits in the frame's stack is part of where the bar sits.
        -- Classic keeps its own box.
        --
        -- ☠ ENABLE RESOURCE BAR STAYS IN THE BODY of the first card, as Show
        -- Debuffs does on the Debuff Bar: it is the PAGE gate, and a header tick
        -- that greyed every other card would surprise people. Shut, that card's
        -- corner says Off while the bar is off. Show Background and Show Border are
        -- their own cards' on/off, so they move into those cards' headers.
        --
        -- ⚠ THE PAGE GATE GREYS EVERY OTHER CARD: its header through dimOn, its
        -- controls through the group gate each builder has always carried.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates } and, where a toggle is hoisted, `hoistToggle`.
        -- The classic branch mounts the SAME builder into the box it always built,
        -- which is what makes "classic is unchanged" structural rather than a
        -- promise -- test_resourcebar_page_builders.lua pins the inventory of each
        -- one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery, which carries the card helper. nil in
        -- classic, which is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper and its two opt-ins, which every card
        -- here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- The page gate, named once: every card but the one holding it greys its
        -- header while the bar is off (its controls grey through the group gate
        -- inside each builder), and the two header ticks grey with it.
        --
        -- ⚠ NO INDEX-1 REPAIR ANY MORE (the old pane first-child gate). DandersUI
        -- Sections' RefreshChildStates spares a child by its `isSectionHeader`
        -- MARK now, not by its position, so a card's band and a pinned panel's
        -- group -- neither of which has a header -- grey every child on their own.
        local function ResourceOffRow(d) return not (d or db).resourceBarEnabled end

        -- ===== THE PAGE'S VOCABULARY, AT PAGE SCOPE =======================
        -- These three tables and the class list used to sit inside the box that
        -- offered them. The cards print the chosen value as their SUMMARY, and a
        -- summary is written OUTSIDE the group's builder -- so the word has to come
        -- out of the same table the dropdown offers, or a card could say one thing
        -- while the control behind it says another. (The Health Bar page hoisted
        -- its six dropdown tables for exactly this reason.)
        --
        -- ⚠ THE CLASS LIST MOVES BUT THE SEED DOES NOT. The list is only data; the
        -- `db.resourceBarClassFilter` seeding block that reads it stays inside the
        -- builder, where it runs at page-build time in both layouts -- a card is
        -- built with the page, so the write still lands at the moment it always did.
        -- Moving it would move WHEN a profile changes shape, which is what the
        -- export byte-identity gate measures.
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

        local anchorOptions = {
            TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"], CENTER= L["Center"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }

        -- Keep Orientation (Horizontal/Vertical) and Reverse Fill as two explicit
        -- controls — clearer than a combined "Fill Direction" dropdown, where an
        -- option like "Bottom to Top" silently changes the orientation too.
        local orientOptions = { HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"] }

        -- Colour mode: Power Type (per-power colours below) / Class / Custom.
        local RESOURCE_COLOR_MODES = {
            POWER_TYPE = L["Power Type"], CLASS = L["Class"], CUSTOM = L["Custom"],
            _order = { "POWER_TYPE", "CLASS", "CUSTOM" },
        }

        -- The texture's display NAME, from the addon's own media resolver -- the one
        -- GUI:CreateTextureDropdown prints on its own button, so a card and the
        -- control behind it cannot disagree. Its own copy: the Health Bar page's
        -- helper of the same name is a local inside THAT page's closure.
        local function TextureName(path)
            local name = DF.GetTextureNameFromPath and DF:GetTextureNameFromPath(path)
            if type(name) == "string" and name ~= "" then return name end
            return nil
        end

        -- ===== SETTINGS (a 280 box in column 1 in classic, the first card under
        -- "General" in modern) =====
        --
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER, as it does for every group on
        -- this page: in classic the box greys its own children while the bar is
        -- off, and a card or a pinned panel has to do the same. One builder serving both is what
        -- stops the two drifting.
        local function BuildResourceSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Built in both layouts: it is the PAGE gate, so no card hoists it
            -- (see the page note). keepEnabled is what keeps it live under the
            -- group's own grey. The seam stays for any future caller.
            if not tools2.hoistToggle then
                local resourceBarEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Resource Bar"], db, "resourceBarEnabled", function()
                    DF:UpdateAllPowerEventRegistration()
                    DF:UpdateAllFrames()
                    tools2.refreshStates()
                end), 30)
                resourceBarEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            group:AddWidget(GUI:CreateCheckbox(parent, L["Healers"], db, "resourceBarShowHealer", function() DF:UpdateAllFrames() end), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Tanks"], db, "resourceBarShowTank", function() DF:UpdateAllFrames() end), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["DPS"], db, "resourceBarShowDPS", function() DF:UpdateAllFrames() end), 30)
            local showInSolo = group:AddWidget(GUI:CreateCheckbox(parent, L["Show in Solo Mode"], db, "resourceBarShowInSoloMode", function() DF:UpdateAllFrames() end), 30)
            showInSolo.hideOn = function() return GUI.SelectedMode == "raid" end
        end

        -- Which roles get a bar, in the ticks' own words. Nothing is said about
        -- Show in Solo Mode: it is the fourth item at most and it is TRUE by
        -- default, so naming it would put a word on almost every profile's card.
        local function ResourceSettingsSummary(d)
            if not d then return "" end
            local parts = {}
            if d.resourceBarShowHealer then parts[#parts + 1] = L["Healers"] end
            if d.resourceBarShowTank   then parts[#parts + 1] = L["Tanks"] end
            if d.resourceBarShowDPS    then parts[#parts + 1] = L["DPS"] end
            return table.concat(parts, " \194\183 ")
        end
        -- The card's corner: "Off" while the page gate is off -- the roles it
        -- would list get no bar -- and the summary above otherwise.
        local function ResourceSettingsCardSummary(d)
            if d and not d.resourceBarEnabled then return L["Off"] end
            return ResourceSettingsSummary(d)
        end

        -- ===== CLASS FILTER (a 280 box in column 1 in classic, the second card
        -- under "General" in modern) =====
        local function BuildResourceClassFilterGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            if not db.resourceBarClassFilter then
                db.resourceBarClassFilter = {}
                for _, info in ipairs(RB_CLASS_LIST) do
                    db.resourceBarClassFilter[info.token] = true
                end
            end

            for _, info in ipairs(RB_CLASS_LIST) do
                group:AddWidget(
                    GUI:CreateCheckbox(parent, info.name, db.resourceBarClassFilter, info.token, function()
                        DF:UpdateAllFrames()
                    end), 25
                )
            end
        end

        -- How many classes still show a bar. The Group Visibility row's shape, and
        -- its arithmetic is the honest one here too: a token absent from the table
        -- has never been unticked, so only an explicit `false` counts as off.
        -- Numbers raw, no locale string invented for a fraction.
        local function ResourceClassFilterSummary(d)
            local filter = d and d.resourceBarClassFilter
            local on = 0
            for _, info in ipairs(RB_CLASS_LIST) do
                if type(filter) ~= "table" or filter[info.token] ~= false then on = on + 1 end
            end
            return format("%d/%d", on, #RB_CLASS_LIST)
        end

        -- ===== SIZE (a 280 box in column 1 in classic, the first card under
        -- "Layout" in modern) =====
        -- ★ THE CONTROLS RENAME THEMSELVES BY ORIENTATION (Aphoex 5/5.1, redesigned as
        -- UX by Krathe 2026-08-22: "it auto matches the health bar depending on the
        -- orientation set but you still control how thick the bar looks").
        --
        -- ☠ THE MECHANICS WERE NEVER WRONG — ONLY THE NAMES LIED. resourceBarWidth and
        -- resourceBarHeight are ORIENTATION-RELATIVE keys: Width is the bar's LENGTH
        -- along its fill axis, Height its THICKNESS across it, and Bars.lua swaps them
        -- onto screen axes for a vertical bar. Match always pins the LENGTH, so greying
        -- the length slider in both orientations was correct behaviour wearing a label
        -- ("Width / Length") that read as a bug on a vertical bar: match visibly fixes
        -- the bar's on-screen HEIGHT there, yet "Height / Thickness" never greyed
        -- (Aphoex 5.1). Renaming per orientation puts the same word on the checkbox and
        -- the slider it greys — "Match Health Bar Height" greys "Height" — and the free
        -- slider is always "Thickness", the one promise the design makes.
        --
        -- ⚠ The rename rides refreshContent (RefreshStates' dynamic-content hook), so it
        -- follows the Orientation dropdown, a profile import and a copy-from-other-mode
        -- alike — anything that ends in RefreshStates. The Orientation dropdown's own
        -- callback gained the RefreshStates call for exactly that.
        --
        -- ⚠ AND THE HOOK STILL FIRES IN A PINNED PANEL. refreshContent is run by
        -- DandersUI Sections' RefreshChildStates, which is exactly what ReflowPane
        -- calls on the group it re-flows -- so tools2.refreshStates renames these
        -- two controls in a panel for the same reason self:RefreshStates renamed
        -- them on the page. What does NOT reach a panel is a refresh driven from
        -- the page, which is why the Orientation dropdown has its own note.
        local function BuildResourceSizeGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            local rbMatch = group:AddWidget(GUI:CreateCheckbox(parent, L["Match Health Bar Width"], db, "resourceBarMatchWidth", function()
                -- RefreshStates so the Adjust For Frame Border row appears/disappears with the tick.
                tools2.refreshStates()
                DF:UpdateAllFrames()
            end), 30)
            -- ☠ THE SECOND SENTENCE IS THE ONE THAT WAS MISSING, AND IT COST A BUG REPORT.
            -- Matching pins the bar by its two ENDS, so the Anchor dropdown's left/right half
            -- stops applying: Top Left, Top and Top Right all render the same row, and the same
            -- for the bottom trio (Aphoex 3.2, "only 3 position anchors work"). The dropdown
            -- keeps all nine because they are all live the moment Match is off — the honest fix
            -- is to say so here rather than to silently drop six entries the user may be about
            -- to need. Worded around "the matched size slider" rather than a control name,
            -- because the control names now change with the orientation.
            rbMatch.tooltip = L["Keeps the resource bar exactly as long as the health bar, following the frame when it resizes. The matched size slider greys out while this is on; Thickness stays yours. Because the bar is pinned by its ends, the Anchor only takes effect along the other axis."]
            rbMatch.refreshContent = function(w, d)
                if w.label then
                    w.label:SetText((d.resourceBarOrientation == "VERTICAL")
                        and L["Match Health Bar Height"] or L["Match Health Bar Width"])
                end
            end

            -- Only meaningful while Match is on, so it sits directly under the switch it
            -- modifies and hides with it. DETERMINISTIC: on (default — matches what
            -- stable 5.2.0 renders; see the key's note in Config.lua) = tuck inside the
            -- frame border band, off = full health-bar length. The first cut gated
            -- an alpha-based auto rule instead and read as doing nothing with an opaque
            -- border (Krathe, 2026-08-22) -- an option whose two states can render the
            -- same pixels is broken as a control, whatever the tooltip says. "Frame
            -- Border" in the name because the resource bar has a border of its OWN on
            -- this page, and a bare "Border" could be either.
            local rbAdjust = group:AddWidget(GUI:CreateCheckbox(parent, L["Adjust For Frame Border"], db, "resourceBarMatchAdjustFrameBorder", function() DF:UpdateAllFrames() end), 30)
            rbAdjust.tooltip = L["Shortens the bar so it sits inside the frame border instead of spanning its full length. Leave off to keep the bar exactly as long as the health bar, with the frame border overlapping its ends."]
            rbAdjust.hideOn = function(d) return not d.resourceBarMatchWidth end

            local widthSlider = group:AddWidget(GUI:CreateSlider(parent, L["Width"], 10, 200, 1, db, "resourceBarWidth", nil, function() DF:LightweightUpdatePowerBarSize() end, true), 55)
            widthSlider.disableOn = function(d) return d.resourceBarMatchWidth end
            widthSlider.refreshContent = function(w, d)
                if w.label then
                    w.label:SetText((d.resourceBarOrientation == "VERTICAL") and L["Height"] or L["Width"])
                end
            end
            group:AddWidget(GUI:CreateSlider(parent, L["Thickness"], 1, 20, 1, db, "resourceBarHeight", nil, function() DF:LightweightUpdatePowerBarSize() end, true), 55)
        end

        -- Either "the length is pinned to the health bar" or the length itself --
        -- one or the other is always meaningless -- then the thickness, which is
        -- yours in both cases. Both halves take the ORIENTATION'S word, exactly as
        -- the controls behind them do, so the card cannot say "Width" over a slider
        -- that reads "Height".
        local function ResourceSizeSummary(d)
            if not d then return "" end
            local vertical = d.resourceBarOrientation == "VERTICAL"
            local parts = {}
            if d.resourceBarMatchWidth then
                parts[#parts + 1] = vertical and L["Match Health Bar Height"] or L["Match Health Bar Width"]
            else
                parts[#parts + 1] = format("%s %d", vertical and L["Height"] or L["Width"],
                                           math.floor(tonumber(d.resourceBarWidth) or 0))
            end
            parts[#parts + 1] = format("%s %d", L["Thickness"], math.floor(tonumber(d.resourceBarHeight) or 0))
            return table.concat(parts, " \194\183 ")
        end

        -- ===== POSITION (a 280 box in column 1 in classic, the second card under
        -- "Layout" in modern, where Frame Level joins it) =====
        local function BuildResourcePositionGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "resourceBarAnchor", function() DF:UpdateAllFrames() end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -50, 50, 1, db, "resourceBarX", nil, function() DF:LightweightUpdatePowerBarPosition() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -50, 50, 1, db, "resourceBarY", nil, function() DF:LightweightUpdatePowerBarPosition() end, true), 55)
        end

        -- The anchor in the dropdown's own words, and the offsets only when they
        -- are doing something -- a card reading "0, 1" on every default profile is
        -- noise (the Border row's rule). Both numbers go in together: an X with no
        -- Y beside it reads as a coordinate with a missing half.
        local function ResourcePositionSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.resourceBarAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local x = math.floor(tonumber(d.resourceBarX) or 0)
            local y = math.floor(tonumber(d.resourceBarY) or 0)
            if x ~= 0 or y ~= 0 then parts[#parts + 1] = format("%d, %d", x, y) end
            return table.concat(parts, " \194\183 ")
        end

        -- ===== APPEARANCE (a 280 box in column 2 in classic, the first card under
        -- "Style" in modern) — mirrors the Health Bar's Texture group:
        -- Texture, Orientation / Reverse Fill, and Smooth Bar Animation in one place. =====
        --
        -- ☠ THE ORIENTATION PICK RE-GATES A DIFFERENT GROUP, which is what makes it
        -- the one callback on this page that cannot just be tools2.refreshStates.
        -- It renames the two SIZE controls through their refreshContent hooks. On
        -- the page that is the Size card's band, which the page pass reaches; a
        -- PINNED Size panel is a separate group in a separate holder, which it does
        -- not -- so the labels there would keep the old orientation's word until
        -- something else re-flowed them. tools.ReflowMounted() is the page-scope
        -- repaint that does reach it, from the card or from a pinned Appearance.
        --
        -- ⚠ WITHOUT THE VALUE SWEEP. This is a STATE change, not a write behind the
        -- widgets' backs, and ReflowMounted(true) mid-drag snaps a slider thumb back
        -- to the last committed step (the helper's own note).
        --
        -- In classic tools2.refreshStates IS self:RefreshStates(), which is exactly
        -- what this callback always did, and there is no tools and nothing to reflow.
        local function OrientationChanged(tools2)
            tools2.refreshStates()
            if tools then tools.ReflowMounted() end
        end

        local function BuildResourceAppearanceGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "resourceBarTexture", function() DF:UpdateAllFrames() end), 55)

            group:AddWidget(GUI:CreateDropdown(parent, L["Orientation"], orientOptions, db, "resourceBarOrientation", function()
                -- RefreshStates so the Size controls rename to the new orientation at once
                -- (their refreshContent hooks — see the Size group).
                OrientationChanged(tools2)
                DF:UpdateAllFrames()
            end), 55)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Reverse Fill Direction"], db, "resourceBarReverseFill", function() DF:UpdateAllFrames() end), 30)

            group:AddWidget(GUI:CreateCheckbox(parent, L["Smooth Bar Animation"], db, "resourceBarSmooth", function() DF:UpdateAllFrames() end), 30)
        end

        -- The texture's name, and the orientation only when it is NOT the plain
        -- horizontal -- the Health Bar Texture row's rule for a value that is the
        -- default on every profile.
        local function ResourceAppearanceSummary(d)
            if not d then return "" end
            local parts = {}
            local name = TextureName(d.resourceBarTexture)
            if name then parts[#parts + 1] = name end
            if d.resourceBarOrientation and d.resourceBarOrientation ~= "HORIZONTAL" then
                local o = orientOptions[d.resourceBarOrientation]
                if o then parts[#parts + 1] = o end
            end
            return table.concat(parts, " \194\183 ")
        end

        -- ===== BACKGROUND (a 280 box in column 2 in classic, the second card
        -- under "Style" in modern) =====
        --
        -- ⚠ SHOW BACKGROUND IS THE CARD'S HEADER TICK in modern (hoistToggle), so
        -- the card's body is the one colour swatch it gates -- no panel, beam or
        -- footer is wrapped round it any more, which is what kept it in the pane
        -- before. Classic still builds the checkbox in its box.
        local function BuildResourceBackgroundGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            -- Suppressed when the CARD's header carries this tick.
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Background"], db, "resourceBarBackgroundEnabled", function()
                    tools2.refreshStates()
                    DF:UpdateAllFrames()
                end), 30)
            end
            local bgColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], db, "resourceBarBackgroundColor", true, nil, function() DF:LightweightUpdateResourceBarBackgroundColor() end, true), 35)
            bgColor.disableOn = function(d) return not d.resourceBarBackgroundEnabled end
        end

        -- ⚠ NO SUMMARY, AND NOTHING IS INVENTED TO MAKE ONE. A swatch has no word;
        -- the header tick says Off in the corner when the background is off.

        -- ===== BORDER (a 280 box in column 2 in classic, the third card under
        -- "Style" in modern) =====
        -- Include set tailored for a resource indicator:
        -- alpha / inset / blendMode / gradient / shadow keep the visual
        -- toolkit; classColor / roleColor match the bar's optional class
        -- tinting (resourceBarClassColor) for cohesion. Skipped: animate
        -- (resource bar is decoration, not an alert surface), offset (bar
        -- has its own X/Y positioning controls above), colorByTime /
        -- colorByType (no aura-state context).
        --
        -- ⚠ noShowToggle IS THE HOIST -- the Pet Frames border row's move, verbatim.
        -- With it the built-in Show Border checkbox is not built and the card's
        -- header carries that tick instead; showKey is still read, so borderOff
        -- still greys the other sixteen exactly as before.
        local function BuildResourceBorderGroup(tools2)
            GUI:CreateBorderControls(tools2.group, db, "resourceBar", {
                parent       = tools2.parent,
                include      = { alpha = true, inset = true, blendMode = true,
                                 gradient = true, shadow = true,
                                 classColor = true, roleColor = true },
                fullUpdate   = function() DF:LightweightUpdateResourceBarBorder() end,
                lightUpdate  = function() DF:LightweightUpdateResourceBarBorder() end,
                lightColors  = function() DF:LightweightUpdateResourceBarBorderColor() end,
                refreshStates = tools2.refreshStates,
                sizeMin = 1, sizeMax = 6, sizeStep = 1,
                noShowToggle = tools2.hoistToggle or nil,
                -- ☠ THE PAGE GATE, THROUGH THE FACTORY'S OWN DOOR. Every other
                -- builder on this page greys behind resourceBarEnabled with
                -- group.disableChildrenOn; this one cannot, because
                -- CreateBorderControls owns the group and writes disableOn onto each
                -- of the seventeen itself -- so the gate goes in as the CONSUMER
                -- gate it is, which the factory composes on top of borderOff and
                -- every widget's own predicate. Modern -- the card and its pinned
                -- panel -- passes it; nil in classic, where the box's
                -- disableChildrenOn does the same job it always has.
                disableWhen  = tools and ResourceOffRow or nil,
            })
        end

        -- The two lightweight passes every border control drives between them --
        -- what the header tick's commit runs.
        local function ApplyResourceBorder()
            DF:LightweightUpdateResourceBarBorder()
            DF:LightweightUpdateResourceBarBorderColor()
        end

        -- The Pet Frames border summary plus the colour source this include set has
        -- and that one does not: thickness in pixels, the style word, where the
        -- colour comes from when it is not the static swatch, and the alpha only
        -- when it is doing something -- a card reading "Alpha 1.00" on every
        -- default profile is noise.
        local function ResourceBorderSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.resourceBarBorderSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local style = d.resourceBarBorderStyle
            parts[#parts + 1] = (style == "GRADIENT" and L["Gradient"])
                             or (style == "TEXTURE" and L["Texture"])
                             or L["Solid"]
            local src = d.resourceBarBorderColorSource
            if style ~= "GRADIENT" then
                if src == "CLASS" then parts[#parts + 1] = L["Class"]
                elseif src == "ROLE" then parts[#parts + 1] = L["Role"] end
            end
            local c = d.resourceBarBorderColor
            local a = type(c) == "table" and tonumber(c.a) or nil
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            return table.concat(parts, " \194\183 ")
        end

        -- ===== RESOURCE COLORS (a 280 box in column 2 in classic, the last card
        -- under "Style" in modern) =====
        --
        -- ⚠ THE TEN POWER SWATCHES WRITE DF.db.powerColors, which lives at the ROOT
        -- of the profile and is shared by party and raid -- not a per-mode key.
        -- The Reset All to Default button below is their only reset.
        local function BuildResourceColorsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            group:AddWidget(GUI:CreateLabel(parent, L["Customize resource bar colors per power type. Shared across party and raid frames."], 260), 40)
            local rbColorMode = group:AddWidget(GUI:CreateDropdown(parent, L["Color Mode"], RESOURCE_COLOR_MODES, db, "resourceBarColorMode", function()
                DF:RefreshAllVisibleFrames()
                tools2.refreshStates()  -- re-evaluate the custom colour picker's hideOn
            end), 54)
            rbColorMode.tooltip = L["Power Type gives each resource its own game colour — blue mana, yellow energy, red rage. Class colours every bar by the unit's class instead, and Custom uses one fixed colour for everyone."]

            -- Custom colour — only shown in Custom mode.
            local resourceCustomColor = GUI:CreateColorPicker(parent, L["Custom Color"], db, "resourceBarCustomColor", false, function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true)
            resourceCustomColor.hideOn = function() return (db.resourceBarColorMode or "POWER_TYPE") ~= "CUSTOM" end
            group:AddWidget(resourceCustomColor, 30)

            -- ☠ THE SEED AND THE TEN THAT FOLLOW IT STAY WHERE THEY WERE, inside the
            -- builder and ahead of the picker that reads each one. They are
            -- build-time writes to a non-profile table, and a card is built with the
            -- page, so they still land at the moment they always did. Moving them
            -- would move WHEN a profile changes shape.
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
                group:AddWidget(GUI:CreateColorPicker(parent, info.name, powerColorsDB, token, false, function()
                    DF:RefreshAllVisibleFrames()
                end, function()
                    DF:RefreshAllVisibleFrames()
                end, true), 30)
            end

            local resetPowerBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            GUI:StyleButton(resetPowerBtn, { width = 260, height = 24, text = L["Reset All to Default"] })
            resetPowerBtn:SetScript("OnClick", function()
                for _, info in ipairs(POWER_LIST) do
                    local default = PowerBarColor[info.token]
                    if default then
                        powerColorsDB[info.token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                    end
                end
                DF:RefreshAllVisibleFrames()
                -- ☠ WHAT THE REBUILD WAS BUYING, AND WHY A PANE MUST NOT PAY FOR IT
                -- THAT WAY -- the Colors page's RepaintSwatches, same reason. The
                -- button writes ten swatches behind the widgets' backs, so they have
                -- to be repainted; classic has always done that with a whole page
                -- Refresh and keeps doing exactly that. Inside a pane a rebuild
                -- retires every widget on the page, and CreatePopoutPageTools' own
                -- prologue closes every open panel on the way in -- so the panel the
                -- button was clicked in would slam shut under the user's hand. The
                -- pane's value sweep IS the repaint: RefreshChildValues calls each
                -- control's `refreshValue`, which for a colour picker is its swatch
                -- update, and ReflowMounted(true) runs it on every mounted pane
                -- including a pinned second one.
                -- Classic takes the same sweep over this box (every swatch the
                -- button wrote is a colour picker in it); the page rebuild it used
                -- to pay leaked the page, and is only the fallback now. A modern
                -- CARD sweeps its own band and then any pinned copy of it.
                if tools2.popout then
                    tools.ReflowMounted(true)
                elseif group.RefreshChildValues then
                    group:RefreshChildValues()
                    if tools then tools.ReflowMounted(true) end
                elseif pageResource and pageResource.Refresh then
                    pageResource:Refresh()
                end
            end)
            group:AddWidget(resetPowerBtn, 30)
        end

        -- Where the colour comes from, in the dropdown's own words. The ten power
        -- swatches have no four of anything worth naming (the Class Colors card's
        -- rule), and the custom swatch is only visible under one of the three modes
        -- the word already reports.
        local function ResourceColorsSummary(d)
            if not d then return "" end
            return RESOURCE_COLOR_MODES[d.resourceBarColorMode] or ""
        end

        -- ===== THE MOUNTS ==================================================
        -- One arm per group, in the order classic has always added them, so the
        -- classic page is unmoved: Settings (1), Class Filter (1), Size (1),
        -- Position (1), Appearance (2), Background (2), Border (2), Frame Level (1)
        -- and Resource Colors (2). The cards follow the same order -- the one the
        -- one-column fold reads -- with Frame Level inside Position.
        if classicLayout then
            local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
            settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Resource Bar Settings"]), 40)
            BuildResourceSettingsGroup({
                group = settingsGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(settingsGroup, nil, 1)
        else
            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Debuff Bar's placement: they act on cards in both columns.
            Add(tools.SectionControls(self.child), 24, "both")
            -- The category header the two General cards sit under.
            Add(GUI:CreateHeader(self.child, L["General"]), 40, 1)
            -- ☠ NO TICK: Enable Resource Bar is the page gate and stays in the body
            -- (see the page note), built by the builder exactly as classic builds
            -- it. No pin: which roles get a bar is behaviour, not looks.
            local band = OpenSection(L["Resource Bar Settings"], "resource_settings", 1, ResourceSettingsCardSummary)
            BuildResourceSettingsGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        if classicLayout then
            local classFilterGroup = GUI:CreateSettingsGroup(self.child, 280)
            classFilterGroup:AddWidget(GUI:CreateHeader(self.child, L["Class Filter"]), 40)
            BuildResourceClassFilterGroup({
                group = classFilterGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(classFilterGroup, nil, 1)
        else
            -- Thirteen class ticks, two per row on a wide card. No pin: which
            -- classes get a bar is behaviour. Greys its header with the page gate.
            local band = OpenSection(L["Class Filter"], "resource_classfilter", 1, ResourceClassFilterSummary, ResourceOffRow)
            BuildResourceClassFilterGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        if classicLayout then
            local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
            sizeGroup:AddWidget(GUI:CreateHeader(self.child, L["Size"]), 40)
            BuildResourceSizeGroup({
                group = sizeGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(sizeGroup, nil, 1)
        else
            Add(GUI:CreateHeader(self.child, L["Layout"]), 40, 1)
            -- A pin: the bar's length and thickness are how it LOOKS.
            local band = OpenSection(L["Size"], "resource_size", 1, ResourceSizeSummary, ResourceOffRow, nil,
                BuildResourceSizeGroup)
            BuildResourceSizeGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        if classicLayout then
            local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
            positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
            BuildResourcePositionGroup({
                group = positionGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(positionGroup, nil, 1)
        else
            -- A pin: where the bar sits is how it LOOKS.
            local band = OpenSection(L["Position"], "resource_position", 1, ResourcePositionSummary, ResourceOffRow, nil,
                BuildResourcePositionGroup)
            BuildResourcePositionGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            -- ☠ FRAME LEVEL, THE PAGE'S LONE CONTROL, MOVED IN HERE (see the page
            -- note). The slider classic builds in its own box, same key, same
            -- two callback slots (nothing on commit, the frame-level reapply on
            -- the drag tick) and the same shared tooltip; the band's group gate
            -- greys it with the rest of Position. Card-only: a pinned Position
            -- panel holds the builder's three.
            band:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "resourceBarFrameLevel", nil, function() DF:LightweightUpdateResourceBarFrameLevel() end, true)), 55)
            CloseSection(band)
        end

        if classicLayout then
            local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
            appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
            BuildResourceAppearanceGroup({
                group = appearanceGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(appearanceGroup, nil, 2)
        else
            -- The category header the four Style cards sit under.
            Add(GUI:CreateHeader(self.child, L["Style"]), 40, 2)
            local band = OpenSection(L["Appearance"], "resource_appearance", 2, ResourceAppearanceSummary, ResourceOffRow, nil,
                BuildResourceAppearanceGroup)
            BuildResourceAppearanceGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        if classicLayout then
            local bgGroup = GUI:CreateSettingsGroup(self.child, 280)
            bgGroup:AddWidget(GUI:CreateHeader(self.child, L["Background"]), 40)
            BuildResourceBackgroundGroup({
                group = bgGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(bgGroup, nil, 2)
        else
            -- ☠ SHOW BACKGROUND IS THE HEADER'S TICK; the builder skips its own
            -- (hoistToggle). The commit is what the in-body checkbox ran, plus a
            -- reflow for a pinned copy -- never a page rebuild. It greys with the
            -- page gate. No summary: the tick's Off is the whole of what a shut
            -- card has to say.
            local band = OpenSection(L["Background"], "resource_background", 2, nil, ResourceOffRow, nil,
                BuildResourceBackgroundGroup, {
                    db = db, key = "resourceBarBackgroundEnabled", label = L["Show Background"],
                    disableOn = ResourceOffRow,
                    onChanged = function()
                        self:RefreshStates()
                        DF:UpdateAllFrames()
                        tools.ReflowMounted()
                    end,
                })
            BuildResourceBackgroundGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        if classicLayout then
            local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
            borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
            borderGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
            BuildResourceBorderGroup({
                group = borderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(borderGroup, nil, 2)
        else
            -- ☠ SHOW BORDER IS THE HEADER'S TICK, so the toolkit is told not to
            -- build its own (hoistToggle -> noShowToggle). The key is still read
            -- inside, so the other sixteen grey exactly as before. The commit is
            -- what the suppressed checkbox ran, plus a reflow for a pinned copy --
            -- never a page rebuild. It greys with the page gate.
            local band = OpenSection(L["Border"], "resource_border", 2, ResourceBorderSummary, ResourceOffRow, nil,
                BuildResourceBorderGroup, {
                    db = db, key = "resourceBarShowBorder", label = L["Show Border"],
                    disableOn = ResourceOffRow,
                    onChanged = function()
                        ApplyResourceBorder()
                        self:RefreshStates()
                        tools.ReflowMounted()
                    end,
                })
            BuildResourceBorderGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = true,
            })
            CloseSection(band)
        end

        -- ===== FRAME LEVEL (a 280 box in column 1 in classic; in modern it is
        -- the last control of the Position card, above) =====
        if classicLayout then
            local frameLevelGroup = GUI:CreateSettingsGroup(self.child, 280)
            frameLevelGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Level"]), 40)
            frameLevelGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end
            frameLevelGroup:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "resourceBarFrameLevel", nil, function() DF:LightweightUpdateResourceBarFrameLevel() end, true)), 55)
            Add(frameLevelGroup, nil, 1)
        else
            -- Modern: Frame Level is the last control of the Position card.
        end

        if classicLayout then
            local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
            colorGroup:AddWidget(GUI:CreateHeader(self.child, L["Resource Colors"]), 40)
            BuildResourceColorsGroup({
                group = colorGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(colorGroup, nil, 2)
        else
            -- A pin: which colour each bar is drawn in is how it LOOKS.
            local band = OpenSection(L["Resource Colors"], "resource_colors", 2, ResourceColorsSummary, ResourceOffRow, nil,
                BuildResourceColorsGroup)
            BuildResourceColorsGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end
    end)
    
    -- Bars > Absorbs (combined Absorb Shield + Heal Absorb with collapsible sections)
    local pageAbsorb = CreateSubTab("bars", "bars_absorb", L["Absorbs"])
    BuildPage(pageAbsorb, function(self, db, Add, AddSpace)
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

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: two collapsible sections over
        -- LOOSE WIDGETS -- no settings boxes at all. Twenty-one controls go
        -- straight onto the page under "Absorb Shield" and fifteen under "Heal
        -- Absorb", each with its own slot height and its own column.
        --
        -- MODERN is the Debuff Bar's collapsible-card design: each section's pile
        -- is ONE card, and the two cards sit SIDE BY SIDE, one per page column,
        -- when the window is wide enough (testers compared the two bars and did
        -- not want to scroll between them). Everything is on the card -- nothing
        -- is behind a popout any more -- two settings per row, dim captions, and
        -- Expand All / Collapse All at the top:
        --
        --   column 1   Absorb Shield
        --   column 2   Heal Absorb
        --
        -- ☠ THE BUILDERS TAKE AN `add` OR A `group`. This was the sweep's first
        -- loose-widget page: classic has no box, it calls `AddToSection(w, h, col)`
        -- and the COLUMN is part of what it always did, so classic hands its own
        -- `add` in and every other line of the builder is the page's own source,
        -- unmoved. A card (and its pinned panel) hands a `group` instead, exactly
        -- like every other page's builder, and the builder adds into it with the
        -- column dropped -- a card is one flow. test_absorbs_page_builders.lua
        -- pins the classic Add order, heights and columns against the census
        -- taken before the move.
        --
        -- ☠ THE FULL-WIDTH SECTIONS ARE CLASSIC'S ONLY. Classic keeps its two
        -- collapsible sections over loose widgets, and the spacer between them;
        -- in modern the card IS the section, and a full-width section or spacer
        -- between the two cards would push Heal Absorb under Absorb Shield.
        --
        -- ⚠ NEITHER CARD CARRIES A TICK. There is no enable key for either bar --
        -- the Display Mode dropdown IS the master, and neither list of modes has an
        -- off. Both are pinnable: every control in them decides how a bar looks.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery, which carries the card helper. nil in
        -- classic, which is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper and its two opt-ins, which every card
        -- here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ===== THE PAGE'S DROPDOWN VOCABULARY, AT PAGE SCOPE ==============
        -- The cards print the chosen mode as their SUMMARY, and a summary is written
        -- OUTSIDE the group's builder -- so the word has to come out of the same table
        -- the dropdown offers, or a card could say one thing while the control behind
        -- it says another. (The Health Bar page hoisted its six dropdown tables for
        -- exactly this reason.)
        --
        -- ⚠ Orientation and Anchor must be page-scope for a SECOND reason: the absorb
        -- shield and the heal absorb builders BOTH read them, and each is a closure of
        -- its own. Same tables, same values, one declaration.
        local modeOptions = {
            OVERLAY = L["Overlay (on health bar)"],
            ATTACHED = L["Attached to Health"],
            ATTACHED_OVERFLOW = L["Attached + Overflow"],
            FLOATING = L["Floating Bar"],
        }
        local healModeOptions = {
            OVERLAY = L["Overlay (on health bar)"],
            ATTACHED = L["Attached to Health"],
            FLOATING = L["Floating Bar"],
        }
        local orientOptions = { HORIZONTAL= L["Horizontal"], VERTICAL= L["Vertical"] }
        local anchorOptions = {
            TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"], CENTER= L["Center"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }

        -- The texture's display NAME, from the addon's own media resolver -- the
        -- one GUI:CreateTextureDropdown prints on its own button, so a card and the
        -- control behind it cannot disagree. Its own copy: the Health Bar and
        -- Resource Bar helpers of the same name are locals inside THEIR closures.
        local function TextureName(path)
            local name = DF.GetTextureNameFromPath and DF:GetTextureNameFromPath(path)
            if type(name) == "string" and name ~= "" then return name end
            return nil
        end

        -- ===== ABSORB SHIELD SECTION =====
        -- ☠ CLASSIC'S ONLY -- in modern the card is the section (see the page note).
        -- An expression rather than an arm, the Health Bar gradient box's idiom:
        -- classic's two arms below stay exactly what they were.
        local absorbSection = classicLayout
            and Add(GUI:CreateCollapsibleSection(self.child, L["Absorb Shield"], true), 36, "both")
            or nil
        currentSection = absorbSection

        -- ===== ABSORB SHIELD (twenty-one loose widgets in classic, the first
        -- card, column 1, in modern) =====
        --
        -- ⚠ THE STRIPE MERGE STAYS INSIDE THE BUILDER. It augments the option table
        -- the dropdown is about to be handed, which is the builder's own business;
        -- moving it out would put a page-scope table in front of two dropdowns that
        -- have always had one each.
        --
        -- ⚠ AND SO DOES THE "Floating Bar Position" HEADER -- the sweep's first
        -- header INSIDE a pane, and now inside a card, on a row of its own. Classic needs it built (it is a widget on the page
        -- like any other), and one builder serving both is what stops the layouts
        -- drifting; in a pane it earns its place a second time, because FLOATING
        -- mode shows fourteen controls in one stack and the header is what says
        -- where the general four stop and the nine floating ones begin. It hides
        -- with them in every other mode.
        local function BuildAbsorbShieldGroup(tools2)
            local add, parent = tools2.add, tools2.parent
            -- A card or a pinned panel hands a group: add into it, column dropped.
            if not add then
                local group = tools2.group
                add = function(w, h) return group:AddWidget(w, h) end
            end

            add(GUI:CreateDropdown(parent, L["Display Mode"], modeOptions, db, "absorbBarMode", function()
                tools2.refreshStates()
                DF:UpdateAllFrames()
            end), 55, 1)

            local textureOptions = DF:GetTextureList()
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
            add(GUI:CreateTextureDropdown(parent, L["Texture"], db, "absorbBarTexture", function() DF:UpdateAllFrames() end, textureOptions), 55, 1)

            add(GUI:CreateColorPicker(parent, L["Bar Color"], db, "absorbBarColor", true, nil, function() DF:LightweightUpdateAbsorbBarColor() end, true), 35, 1)

            local blendOptions = { BLEND= L["Normal (BLEND)"], ADD= L["Additive (ADD)"] }
            add(GUI:CreateDropdown(parent, L["Blend Mode"], blendOptions, db, "absorbBarBlendMode", function() DF:UpdateAllFrames() end), 55, 1)

            local overlayRev = add(GUI:CreateCheckbox(parent, L["Reverse Overlay Fill"], db, "absorbBarOverlayReverse", function() DF:UpdateAllFrames() end), 25, 1)
            overlayRev.hideOn = function(d) return d.absorbBarMode ~= "OVERLAY" and d.absorbBarMode ~= "ATTACHED_OVERFLOW" end

            local absorbClampOptions = {
                [0] = L["None (no clamping)"],
                [1] = L["Missing Health"],
                [2] = L["Max Health"],
            }
            local absorbClampDropdown = add(GUI:CreateDropdown(parent, L["Clamp Mode"], absorbClampOptions, db, "absorbBarAttachedClampMode", function() DF:UpdateAllFrames() end), 55, 1)
            absorbClampDropdown.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" and d.absorbBarMode ~= "ATTACHED_OVERFLOW" end

            local absorbShowOvershield = add(GUI:CreateCheckbox(parent, L["Show Overshield Glow"], db, "absorbBarShowOvershield", function() DF:UpdateAllFrames() end), 25, 1)
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
            local absorbOvershieldStyle = add(GUI:CreateDropdown(parent, L["Glow Style"], absorbOvershieldStyleOptions, db, "absorbBarOvershieldStyle", function() DF:UpdateAllFrames() end), 55, 1)
            absorbOvershieldStyle.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
            absorbOvershieldStyle.disableOn = function(d) return not d.absorbBarShowOvershield end

            local absorbOvershieldColor = add(GUI:CreateColorPicker(parent, L["Glow Color"], db, "absorbBarOvershieldColor", false, nil, function() DF:UpdateAllFrames() end), 35, 1)
            absorbOvershieldColor.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
            absorbOvershieldColor.disableOn = function(d) return not d.absorbBarShowOvershield end

            local absorbOvershieldAlpha = add(GUI:CreateSlider(parent, L["Glow Alpha"], 0.1, 1, 0.05, db, "absorbBarOvershieldAlpha", nil, function() DF:UpdateAllFrames() end, true), 55, 1)
            absorbOvershieldAlpha.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
            absorbOvershieldAlpha.disableOn = function(d) return not d.absorbBarShowOvershield end

            local absorbOvershieldReverse = add(GUI:CreateCheckbox(parent, L["Reverse Position"], db, "absorbBarOvershieldReverse", function() DF:UpdateAllFrames() end), 25, 1)
            absorbOvershieldReverse.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
            absorbOvershieldReverse.disableOn = function(d) return not d.absorbBarShowOvershield end
            absorbOvershieldReverse.tooltip = L["Moves the glow to the opposite side (no HP side instead of max HP side)."]

            -- Floating mode settings (column 2)
            local floatingHeader = add(GUI:CreateHeader(parent, L["Floating Bar Position"]), 45, 2)
            floatingHeader.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local orientDropdown = add(GUI:CreateDropdown(parent, L["Orientation"], orientOptions, db, "absorbBarOrientation", function() DF:UpdateAllFrames() end), 55, 1)
            orientDropdown.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local revFill = add(GUI:CreateCheckbox(parent, L["Reverse Fill"], db, "absorbBarReverse", function() DF:UpdateAllFrames() end), 25, 2)
            revFill.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local widthSlider = add(GUI:CreateSlider(parent, L["Width"], 10, 200, 1, db, "absorbBarWidth", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
            widthSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local heightSlider = add(GUI:CreateSlider(parent, L["Height"], 1, 30, 1, db, "absorbBarHeight", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
            heightSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local anchorDropdown = add(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "absorbBarAnchor", function() DF:UpdateAllFrames() end), 55, 1)
            anchorDropdown.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local xSlider = add(GUI:CreateSlider(parent, L["Offset X"], -50, 50, 1, db, "absorbBarX", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
            xSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local ySlider = add(GUI:CreateSlider(parent, L["Offset Y"], -50, 50, 1, db, "absorbBarY", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
            ySlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local bgColorPicker = add(GUI:CreateColorPicker(parent, L["Background Color"], db, "absorbBarBackgroundColor", true, nil, function() DF:LightweightUpdateAbsorbBarColor() end, true), 35, 2)
            bgColorPicker.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

            local levelSlider = add(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, "absorbBarFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("absorb") end, true)), 55, 1)
            levelSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        end

        -- The display mode in the dropdown's own words, then the texture's name
        -- through the addon's own resolver -- the Health Bar Background row's
        -- shape. The mode goes first because it is the one pick that changes what
        -- the other twenty controls are FOR.
        local function AbsorbShieldSummary(d)
            if not d then return "" end
            local parts = {}
            local mode = modeOptions[d.absorbBarMode]
            if mode then parts[#parts + 1] = mode end
            local name = TextureName(d.absorbBarTexture)
            if name then parts[#parts + 1] = name end
            return table.concat(parts, " \194\183 ")
        end

        if classicLayout then
            -- Straight onto the page, in the columns and at the heights it always
            -- used: `add` IS AddToSection here, so this arm is the old code path
            -- with the call renamed.
            BuildAbsorbShieldGroup({
                add = AddToSection,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
        else
            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Debuff Bar's placement: they act on cards in both columns.
            Add(tools.SectionControls(self.child), 24, "both")
            -- Column 1, pinnable. No tick: the Display Mode pick is the master.
            local band = OpenSection(L["Absorb Shield"], "absorbs_shield", 1, AbsorbShieldSummary, nil, nil,
                BuildAbsorbShieldGroup)
            BuildAbsorbShieldGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        currentSection = nil
        -- ☠ CLASSIC'S ONLY: a "both" spacer between the two cards would end
        -- column 1 and push Heal Absorb under Absorb Shield.
        if classicLayout then AddSpace(GUI.Space.section, "both") end

        -- ===== HEAL ABSORB SECTION =====
        -- ☠ CLASSIC'S ONLY, as the Absorb Shield section above.
        local healAbsorbSection = classicLayout
            and Add(GUI:CreateCollapsibleSection(self.child, L["Heal Absorb"], true), 36, "both")
            or nil
        currentSection = healAbsorbSection

        -- ===== HEAL ABSORB (fifteen loose widgets in classic, the second card,
        -- column 2, in modern) =====
        --
        -- ⚠ THE BLURB TRAVELS WITH THE CONTROLS. It says what a heal absorb IS,
        -- which is the one thing a user opening this card may not know, so it is
        -- the group's first widget in every layout, on a row of its own in a card.
        local function BuildHealAbsorbGroup(tools2)
            local add, parent = tools2.add, tools2.parent
            -- A card or a pinned panel hands a group: add into it, column dropped.
            if not add then
                local group = tools2.group
                add = function(w, h) return group:AddWidget(w, h) end
            end

            add(GUI:CreateLabel(parent, L["Shows effects that reduce incoming healing (like Necrotic stacks)."], 260), 25, 1)

            add(GUI:CreateDropdown(parent, L["Display Mode"], healModeOptions, db, "healAbsorbBarMode", function()
                tools2.refreshStates()
                DF:UpdateAllFrames()
            end), 55, 1)

            local healTextureOptions = DF:GetTextureList()
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
            add(GUI:CreateTextureDropdown(parent, L["Texture"], db, "healAbsorbBarTexture", function() DF:UpdateAllFrames() end, healTextureOptions), 55, 1)

            add(GUI:CreateColorPicker(parent, L["Bar Color"], db, "healAbsorbBarColor", true, nil, function() DF:LightweightUpdateHealAbsorbBarColor() end, true), 35, 1)

            local healBlendOptions = { BLEND= L["Normal (BLEND)"], ADD= L["Additive (ADD)"] }
            add(GUI:CreateDropdown(parent, L["Blend Mode"], healBlendOptions, db, "healAbsorbBarBlendMode", function() DF:UpdateAllFrames() end), 55, 1)

            local healOverlayRev = add(GUI:CreateCheckbox(parent, L["Reverse Overlay Fill"], db, "healAbsorbBarOverlayReverse", function() DF:UpdateAllFrames() end), 25, 1)
            healOverlayRev.hideOn = function(d) return d.healAbsorbBarMode ~= "OVERLAY" end

            -- Heal Absorb Floating mode settings (column 2)
            local healFloatingHeader = add(GUI:CreateHeader(parent, L["Floating Bar Position"]), 45, 2)
            healFloatingHeader.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

            local healOrientDropdown = add(GUI:CreateDropdown(parent, L["Orientation"], orientOptions, db, "healAbsorbBarOrientation", function() DF:UpdateAllFrames() end), 55, 1)
            healOrientDropdown.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

            local healRevFill = add(GUI:CreateCheckbox(parent, L["Reverse Fill"], db, "healAbsorbBarReverse", function() DF:UpdateAllFrames() end), 25, 2)
            healRevFill.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

            local healWidthSlider = add(GUI:CreateSlider(parent, L["Width"], 10, 200, 1, db, "healAbsorbBarWidth", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
            healWidthSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

            local healHeightSlider = add(GUI:CreateSlider(parent, L["Height"], 1, 30, 1, db, "healAbsorbBarHeight", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
            healHeightSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

            local healAnchorDropdown = add(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "healAbsorbBarAnchor", function() DF:UpdateAllFrames() end), 55, 1)
            healAnchorDropdown.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

            local healXSlider = add(GUI:CreateSlider(parent, L["Offset X"], -50, 50, 1, db, "healAbsorbBarX", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
            healXSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

            local healYSlider = add(GUI:CreateSlider(parent, L["Offset Y"], -50, 50, 1, db, "healAbsorbBarY", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
            healYSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

            local healBgColorPicker = add(GUI:CreateColorPicker(parent, L["Background Color"], db, "healAbsorbBarBackgroundColor", true, nil, function() DF:LightweightUpdateHealAbsorbBarColor() end, true), 35, 2)
            healBgColorPicker.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        end

        -- The same two words the shield's card prints, out of this bar's own mode
        -- table: two cards side by side reading the same shape is the point.
        local function HealAbsorbSummary(d)
            if not d then return "" end
            local parts = {}
            local mode = healModeOptions[d.healAbsorbBarMode]
            if mode then parts[#parts + 1] = mode end
            local name = TextureName(d.healAbsorbBarTexture)
            if name then parts[#parts + 1] = name end
            return table.concat(parts, " \194\183 ")
        end

        if classicLayout then
            BuildHealAbsorbGroup({
                add = AddToSection,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
        else
            -- Column 2, beside Absorb Shield when the window is wide. Pinnable.
            local band = OpenSection(L["Heal Absorb"], "absorbs_healabsorb", 2, HealAbsorbSummary, nil, nil,
                BuildHealAbsorbGroup)
            BuildHealAbsorbGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        currentSection = nil
    end)
    
    -- Bars > Heal Prediction
    local pageHealPrediction = CreateSubTab("bars", "bars_healpred", L["Heal Prediction"])
    BuildPage(pageHealPrediction, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"healPrediction"}, L["Heal Prediction"], "bars_healpred"), 25, 2)

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: three 280 boxes -- Settings and
        -- Floating Bar Position down column 1, Floating Bar Anchor in column 2,
        -- the last two hiding wholesale unless the bar is floating.
        --
        -- MODERN is the Debuff Bar's collapsible-card design: one card per box,
        -- two settings per row inside a wide enough card, dim captions, Expand
        -- All / Collapse All at the top, and two page columns -- what the bar is
        -- and does on the left, where a floating bar sits on the right:
        --
        --   column 1   Heal Prediction        (the page's master switch, in its body)
        --   column 2   Floating Bar Position  (hidden unless the bar is floating)
        --              Floating Bar Anchor    (hidden unless the bar is floating)
        --
        -- ☠ ENABLE HEAL PREDICTION STAYS IN THE BODY, as Show Debuffs does on the
        -- Debuff Bar: it is the PAGE gate, and a header tick that greyed every
        -- other card would surprise people. So the first card takes no tick and
        -- no hoistToggle; shut, its corner says "Off" while the bar is off.
        --
        -- ☠ THE FLOATING hideOn GOES ON THE CARD, header and band together
        -- (OpenSection's hideFn), off the one predicate classic's boxes use -- so
        -- box and card cannot drift. The Display Mode pick makes the two floating
        -- cards appear and disappear through the page's own state pass.
        --
        -- ⚠ THE PAGE GATE GREYS THE TWO FLOATING HEADERS (dimOn). Their controls
        -- grey on their own: every widget here carries `disableOn = not
        -- healPredictionEnabled`, inside the builders, in both layouts.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates }. The classic branch mounts the SAME builder into
        -- the box it always built, which is what makes "classic is unchanged"
        -- structural rather than a promise -- test_healpred_page_builders.lua pins
        -- the inventory of each one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery, which carries the card helper. nil in
        -- classic, which is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper and its two opt-ins, which every card
        -- here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- The two predicates the page turns on. The floating one is named once and
        -- handed to BOTH layouts -- a box's hideOn in classic, a card's in modern
        -- -- so the two cannot drift. The gate only greys the cards' HEADERS: the
        -- controls already grey, one by one, inside the builders.
        local function HealPredOffRow(d) return not (d or db).healPredictionEnabled end
        local function HealPredFloatingHiddenOn(d) return d.healPredictionMode ~= "FLOATING" end

        -- ===== THE PAGE'S VOCABULARY, AT PAGE SCOPE =======================
        -- The rows print the chosen value as their SUMMARY, and a summary is written
        -- OUTSIDE the group's builder -- so the word has to come out of the same
        -- table the dropdown offers, or a row could say one thing while the control
        -- behind it says another.
        local modeOptions = { OVERLAY= L["Attached to Health"], FLOATING= L["Floating Bar"] }
        local showModeOptions = {
            ALL = L["All Incoming"], MINE = L["My Heals"], OTHERS = L["Others' Heals"],
            SPLIT = L["Split (Mine + Others)"],
            _order = { "ALL", "MINE", "OTHERS", "SPLIT" },
        }
        local orientOptions = { HORIZONTAL= L["Horizontal"], VERTICAL= L["Vertical"] }
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }

        -- ===== SETTINGS (a 280 box in column 1 in classic, the first card in
        -- column 1 in modern) =====
        --
        -- ☠ THE COLOUR PICKERS ARE THE ONE PLACE THIS BUILDER BRANCHES ON LAYOUT,
        -- and it is the sweep's first such branch. In classic the picker set is
        -- decided AT BUILD TIME from the db: Split builds two, bound to the mine
        -- and others colours; every other mode builds ONE, bound to whichever
        -- colour that mode uses. Changing the mode therefore has to REBUILD THE
        -- PAGE for the picker to rebind -- which is what the Show Heals From
        -- callback does, and which is fatal inside a pane: a rebuild retires the
        -- pane, and CreatePopoutPageTools' own prologue closes every open panel on
        -- the way in, so the dropdown would slam shut the panel it was clicked in.
        --
        -- Modern -- the card and its pinned panel alike -- builds ALL THREE
        -- instead and gates them with hideOn, so the write targets are identical,
        -- the widget set never changes, and the callback needs nothing more than
        -- the state pass every other dropdown on the page runs. Classic keeps its
        -- conditional build, byte for byte. (A card is not a pane, but a rebuild
        -- would still close the card's own pinned copy, and all three findable by
        -- search is worth having on the page as well.)
        --
        -- ⚠ WHAT THAT COSTS, said plainly: under Mine the pane's picker reads "My
        -- Heals Color" where the box read "Heal Prediction Color", and likewise
        -- for Others. Both labels already ship and both are labels classic itself
        -- uses for that key under Split, so the popout is a strict subset of the
        -- page's own vocabulary -- it is simply always precise instead of
        -- sometimes generic. Search gains by it: all three colours are findable in
        -- the popout layout whatever the mode, where classic can only register the
        -- one it happens to have built.
        local function BuildHealPredictionSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the ROW carries this tick. Still built in classic,
            -- where it is the page's only on/off control.
            if not tools2.hoistToggle then
                local hpEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Heal Prediction"], db, "healPredictionEnabled", function()
                    tools2.refreshStates()
                    DF:UpdateAllFrames()
                end), 30)
                hpEnable.keepEnabled = true
            end

            local overhealCheckbox = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Overheal"], db, "healPredictionShowOverheal", function() DF:UpdateAllFrames() end), 30)
            overhealCheckbox.disableOn = function(d) return not d.healPredictionEnabled end
            overhealCheckbox.tooltip = L["When enabled, shows incoming heals even if they would overheal."]

            -- ⚠ tools2.refreshStates, and nothing else. This pick drives the two
            -- FLOATING ROWS' own hideOn, which live on the page rather than in this
            -- pane -- and the page's RefreshStates is exactly what re-lays the band
            -- they are in. There is nothing to repaint in the other two panes: the
            -- only gate their controls carry is the enable, which this is not.
            local modeDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Display Mode"], modeOptions, db, "healPredictionMode", function()
                tools2.refreshStates()
                DF:UpdateAllFrames()
            end), 55)
            modeDropdown.disableOn = function(d) return not d.healPredictionEnabled end

            local showModeDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Show Heals From"], showModeOptions, db, "healPredictionShowMode", function()
                if not classicLayout then
                    -- Modern holds all three pickers already, so there is nothing
                    -- to rebind -- and a rebuild would close a pinned panel this
                    -- dropdown may have been clicked in.
                    tools2.refreshStates()
                else
                    -- Rebuild so the colour picker(s) rebind to the selected mode.
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end
                DF:UpdateAllFrames()
            end), 55)
            showModeDropdown.disableOn = function(d) return not d.healPredictionEnabled end
            showModeDropdown.tooltip = L["Which incoming heals the bar shows: all sources, only yours, or only from others."]

            local textureOptions = DF:GetTextureList()
            local texDropdown = group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "healPredictionTexture", function() DF:UpdateAllFrames() end, textureOptions), 55)
            texDropdown.disableOn = function(d) return not d.healPredictionEnabled end

            if not classicLayout then
                -- All three, gated by the mode rather than built by it. Split shows
                -- the first two; Mine and Others show one each; All shows the third.
                local myColor = group:AddWidget(GUI:CreateColorPicker(parent, L["My Heals Color"], db, "healPredictionMyColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
                myColor.disableOn = function(d) return not d.healPredictionEnabled end
                myColor.hideOn = function(d)
                    return d.healPredictionShowMode ~= "SPLIT" and d.healPredictionShowMode ~= "MINE"
                end

                local othersColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Others' Heals Color"], db, "healPredictionOthersColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
                othersColor.disableOn = function(d) return not d.healPredictionEnabled end
                othersColor.hideOn = function(d)
                    return d.healPredictionShowMode ~= "SPLIT" and d.healPredictionShowMode ~= "OTHERS"
                end

                local allColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Heal Prediction Color"], db, "healPredictionAllColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
                allColor.disableOn = function(d) return not d.healPredictionEnabled end
                allColor.hideOn = function(d) return d.healPredictionShowMode ~= "ALL" end
            else
                -- Colour picker(s): Split shows both segment colours; other modes show
                -- the single colour for the selected mode. The mode dropdown rebuilds
                -- the page so these rebind when the mode changes.
                if db.healPredictionShowMode == "SPLIT" then
                    local myColor = group:AddWidget(GUI:CreateColorPicker(parent, L["My Heals Color"], db, "healPredictionMyColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
                    myColor.disableOn = function(d) return not d.healPredictionEnabled end
                    local othersColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Others' Heals Color"], db, "healPredictionOthersColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
                    othersColor.disableOn = function(d) return not d.healPredictionEnabled end
                else
                    local showModeColorKey = (db.healPredictionShowMode == "ALL" and "healPredictionAllColor")
                        or (db.healPredictionShowMode == "OTHERS" and "healPredictionOthersColor")
                        or "healPredictionMyColor"
                    local myColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Heal Prediction Color"], db, showModeColorKey, true, nil, function() DF:UpdateAllFrames() end, true), 35)
                    myColor.disableOn = function(d) return not d.healPredictionEnabled end
                end
            end

            local blendOptions = { BLEND= L["Normal (BLEND)"], ADD= L["Additive (ADD)"] }
            local blendDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Blend Mode"], blendOptions, db, "healPredictionBlendMode", function() DF:UpdateAllFrames() end), 55)
            blendDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        end

        -- The display mode and then the source, both in their own dropdown's
        -- words. Nothing is said about the texture or the colours: the mode
        -- decides where the bar is drawn and the source decides what it counts,
        -- which is what someone scanning the page is looking for.
        local function HealPredictionSettingsSummary(d)
            if not d then return "" end
            local parts = {}
            local mode = modeOptions[d.healPredictionMode]
            if mode then parts[#parts + 1] = mode end
            local from = showModeOptions[d.healPredictionShowMode]
            if from then parts[#parts + 1] = from end
            return table.concat(parts, " \194\183 ")
        end
        -- The card's corner: "Off" while the page gate is off -- the values it
        -- would list are not drawn -- and the summary above otherwise.
        local function HealPredictionCardSummary(d)
            if d and not d.healPredictionEnabled then return L["Off"] end
            return HealPredictionSettingsSummary(d)
        end

        if classicLayout then
            local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
            settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Heal Prediction"]), 40)
            BuildHealPredictionSettingsGroup({
                group = settingsGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(settingsGroup, nil, 1)
        else
            -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
            -- Debuff Bar's placement: they act on cards in both columns.
            Add(tools.SectionControls(self.child), 24, "both")
            -- ☠ NO TICK: Enable Heal Prediction is the page gate and stays in the
            -- body (see the page note), built by the builder exactly as classic
            -- builds it. Shut, the corner says Off while the bar is off, else the
            -- mode and the source.
            --
            -- A pin: the texture, the colours and the blend are how the bar LOOKS.
            local band = OpenSection(L["Heal Prediction"], "healpred_settings", 1, HealPredictionCardSummary, nil, nil,
                BuildHealPredictionSettingsGroup)
            BuildHealPredictionSettingsGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== FLOATING BAR POSITION (a 280 box in column 1 in classic, the
        -- first card in column 2 in modern) =====
        local function BuildHealPredictionFloatingGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local orientDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Orientation"], orientOptions, db, "healPredictionOrientation", function() DF:UpdateAllFrames() end), 55)
            orientDropdown.disableOn = function(d) return not d.healPredictionEnabled end

            local revFill = group:AddWidget(GUI:CreateCheckbox(parent, L["Reverse Fill"], db, "healPredictionReverse", function() DF:UpdateAllFrames() end), 30)
            revFill.disableOn = function(d) return not d.healPredictionEnabled end

            local widthSlider = group:AddWidget(GUI:CreateSlider(parent, L["Width"], 10, 200, 1, db, "healPredictionWidth", nil, function() DF:UpdateAllFrames() end, true), 55)
            widthSlider.disableOn = function(d) return not d.healPredictionEnabled end

            local heightSlider = group:AddWidget(GUI:CreateSlider(parent, L["Height"], 1, 30, 1, db, "healPredictionHeight", nil, function() DF:UpdateAllFrames() end, true), 55)
            heightSlider.disableOn = function(d) return not d.healPredictionEnabled end
        end

        -- The orientation only when it is NOT the plain horizontal -- the Health
        -- Bar Texture row's rule for a value that is the default on every profile
        -- -- then the two sizes, which are always meaningful because this bar has
        -- no match-the-health-bar switch.
        local function HealPredictionFloatingSummary(d)
            if not d then return "" end
            local parts = {}
            if d.healPredictionOrientation and d.healPredictionOrientation ~= "HORIZONTAL" then
                local o = orientOptions[d.healPredictionOrientation]
                if o then parts[#parts + 1] = o end
            end
            parts[#parts + 1] = format("%s %d", L["Width"], math.floor(tonumber(d.healPredictionWidth) or 0))
            parts[#parts + 1] = format("%s %d", L["Height"], math.floor(tonumber(d.healPredictionHeight) or 0))
            return table.concat(parts, " \194\183 ")
        end

        if classicLayout then
            local floatingGroup = GUI:CreateSettingsGroup(self.child, 280)
            floatingGroup:AddWidget(GUI:CreateHeader(self.child, L["Floating Bar Position"]), 40)
            BuildHealPredictionFloatingGroup({
                group = floatingGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            floatingGroup.hideOn = HealPredFloatingHiddenOn
            Add(floatingGroup, nil, 1)
        else
            -- ☠ COLUMN 2, HIDDEN UNLESS THE BAR FLOATS -- header and band together.
            -- Greys its header with the page gate; its controls grey themselves.
            -- A pin: size and fill direction are how the bar LOOKS.
            local band = OpenSection(L["Floating Bar Position"], "healpred_floating", 2, HealPredictionFloatingSummary,
                HealPredOffRow, HealPredFloatingHiddenOn, BuildHealPredictionFloatingGroup)
            BuildHealPredictionFloatingGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end

        -- ===== FLOATING BAR ANCHOR (a 280 box in column 2 in classic, the
        -- second card in column 2 in modern) =====
        local function BuildHealPredictionAnchorGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local anchorDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "healPredictionAnchor", function() DF:UpdateAllFrames() end), 55)
            anchorDropdown.disableOn = function(d) return not d.healPredictionEnabled end

            local xSlider = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -50, 50, 1, db, "healPredictionX", nil, function() DF:UpdateAllFrames() end, true), 55)
            xSlider.disableOn = function(d) return not d.healPredictionEnabled end

            local ySlider = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -50, 50, 1, db, "healPredictionY", nil, function() DF:UpdateAllFrames() end, true), 55)
            ySlider.disableOn = function(d) return not d.healPredictionEnabled end

            local bgColorPicker = group:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], db, "healPredictionBackgroundColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
            bgColorPicker.disableOn = function(d) return not d.healPredictionEnabled end

            -- ⚠ healPredictionFrameLevel is read by the bar code and resolved by
            -- DF:ResolveHealPredictionBarLevel (Frames/Bars.lua). Same shape and range as the
            -- absorb bar's, and FLOATING-only for the same reason: the bound modes take the
            -- ladder's slot, not a slider.
            local hpLevel = group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, "healPredictionFrameLevel", nil, function() DF:UpdateAllFrames() end, true)), 55)
            hpLevel.disableOn = function(d) return not d.healPredictionEnabled end
        end

        -- The anchor in the dropdown's own words, and the offsets only when they
        -- are doing something -- a row reading "0, 0" on every default profile is
        -- noise (the Border row's rule). Both numbers go in together: an X with no
        -- Y beside it reads as a coordinate with a missing half.
        local function HealPredictionAnchorSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.healPredictionAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local x = math.floor(tonumber(d.healPredictionX) or 0)
            local y = math.floor(tonumber(d.healPredictionY) or 0)
            if x ~= 0 or y ~= 0 then parts[#parts + 1] = format("%d, %d", x, y) end
            return table.concat(parts, " \194\183 ")
        end

        if classicLayout then
            local anchorGroup = GUI:CreateSettingsGroup(self.child, 280)
            anchorGroup:AddWidget(GUI:CreateHeader(self.child, L["Floating Bar Anchor"]), 40)
            BuildHealPredictionAnchorGroup({
                group = anchorGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            anchorGroup.hideOn = HealPredFloatingHiddenOn
            Add(anchorGroup, nil, 2)
        else
            -- Under Floating Bar Position, on the same two gates: same bar, same
            -- mode. A pin: where the bar sits and its colour are how it LOOKS.
            local band = OpenSection(L["Floating Bar Anchor"], "healpred_anchor", 2, HealPredictionAnchorSummary,
                HealPredOffRow, HealPredFloatingHiddenOn, BuildHealPredictionAnchorGroup)
            BuildHealPredictionAnchorGroup({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            CloseSection(band)
        end
    end)
    
    -- ========================================
    -- CATEGORY: Text
    -- ========================================
    CreateCategory("text", L["Text"])
    
    -- LEGACY-TEXT-CLEANUP (v4.4.x): Name/Health/Status built-in text settings are
    -- replaced by the Text Designer, and their settings pages are gone. Remove this
    -- block, the legacy text render path (see DF:IsLegacyTextHidden in
    -- Frames/Core.lua), and the legacy *Text* defaults in Config.lua in a future
    -- release once the Text Designer fully supersedes them.

    -- Text > Text Designer
    local pageTextDesigner = CreateSubTab("text", "text_designer", L["Text Designer"])
    -- ONE BUILD, NOT ONE PER MODE (page.singleModeBuild -- see ONE RETAINED BUILD PER
    -- MODE in GUI/Panel.lua): rebuilt on every party/raid switch, as before.
    -- The designer keeps its own state beside the build (page.dfTD, a classic
    -- island outside page.children, a swapped-in RefreshStates), none of which a
    -- second retained build could share.
    if pageTextDesigner then pageTextDesigner.singleModeBuild = true end
    -- ⚠ Add AND AddSpace GO THROUGH. The designer page has two arms: the classic
    -- split panel, which anchors everything inside frames of its own and needs
    -- neither, and the popout page, which emits BANDS -- and a band can only reach
    -- the page's column through the harness's own Add. Having one is also how the
    -- builder tells which arm it is on.
    BuildPage(pageTextDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        if DF.BuildTextDesignerPage then
            DF.BuildTextDesignerPage(GUI, self, db, Add, AddSpace)
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

    -- Auras > Filter Designer (the page where aura filters are designed)
    --
    -- The page id stays "auras_filterdesigner" whatever the label says. That is
    -- deliberate: every cross-link, Search entry and _fdSelect* entry point already
    -- targets that id, so relabelling costs nothing whereas renaming the id would
    -- mean chasing all of them.
    --
    -- "Filter Designer" — the label finally matches the page id it has always had.
    -- It was called Aura Filters while it did two jobs, one of which was choosing
    -- which filters each bar used; that job moved to the bars, so what is left is
    -- purely the place filters are DESIGNED. It is also buffs-only now, and "Aura
    -- Filters" implied it covered debuffs too.
    local pageFilterDesigner = CreateSubTab("auras", "auras_filterdesigner", L["Filter Designer"])
    -- ONE BUILD, NOT ONE PER MODE (page.singleModeBuild -- see ONE RETAINED BUILD PER
    -- MODE in GUI/Panel.lua): rebuilt on every party/raid switch, as before.
    -- It keeps per-build hooks and frames on the page itself (_filterDesignerBuilt,
    -- _fdBuiltClassic, the _fd* verbs, its spacer and bands) that one page can
    -- only hold for one build.
    if pageFilterDesigner then pageFilterDesigner.singleModeBuild = true end
    BuildPage(pageFilterDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        -- ☠ THE HELPER'S SWEEP RUNS HERE TOO, AND THIS PAGE IS WHY IT HAD TO. The sweep marks
        -- the Power Infusion Helper's seeded lists as CURATED (dfDefaults), which is what gives
        -- their rows the on/off tick instead of the destructive ✕ and puts Reset on screen. It
        -- ran only on the Aura Designer's page build -- so opening the Filter Designer FIRST,
        -- which is exactly what someone inspecting that list does, showed the unmarked version.
        -- Krathe, 2026-09-09, one round after the mark shipped.
        -- ⚠ A MIGRATION HOOK, not a dependency: schema-stamped, so it is one comparison after
        -- the first run, and priest-gated so it costs nothing for anyone else.
        if DF.IsPIHelperAvailable and DF.IsPIHelperAvailable()
            and DF.AuraDesigner and DF.AuraDesigner._priv
            and DF.AuraDesigner._priv.PIH_Sweep then
            DF.AuraDesigner._priv.PIH_Sweep()
        end
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
        -- ☠ Add IS THE TELL, the same one DF.BuildAuraDesignerPage takes below: a
        -- caller holding the harness's own Add can be served bands, one that does
        -- not can only have the island. Handing it over is what takes this page off
        -- the 850px floor.
        if DF.BuildFilterDesignerPage then
            DF.BuildFilterDesignerPage(GUI, self, db, Add, AddSpace)
        end

        -- See Also, after the page's own content. This page positions its panels
        -- absolutely and reports its height through an Add()ed spacer, so anything
        -- Add()ed afterwards lands below them -- which is where a footer belongs.
        --
        -- ⚠ DO NOT DROP THIS ON THE ARGUMENT THAT THE CONSUMER CHIP ROW AT THE TOP OF
        -- THE PAGE MAKES IT REDUNDANT. It is wrong on two counts:
        --
        --   * Every other page under Auras carries a See Also. This page having none
        --     is not "one fewer duplicate", it is the one page that breaks the
        --     pattern.
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
    -- ONE BUILD, NOT ONE PER MODE (page.singleModeBuild -- see ONE RETAINED BUILD PER
    -- MODE in GUI/Panel.lua): rebuilt on every party/raid switch, as before.
    -- Same as the Text Designer: its own island, its own RefreshStates and its
    -- remembered geometry live beside the build, not in it.
    if pageAuraDesigner then pageAuraDesigner.singleModeBuild = true end
    -- ⚠ Add AND AddSpace GO THROUGH. The designer page has two arms: the classic
    -- split panel, which anchors everything inside one frame of its own and needs
    -- neither, and the popout page, which emits BANDS -- and a band can only reach
    -- the page's column through the harness's own Add. Having one is also how the
    -- builder tells which arm it is on.
    BuildPage(pageAuraDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        if DF.BuildAuraDesignerPage then
            DF.BuildAuraDesignerPage(GUI, self, db, Add, AddSpace)
        end
    end)

    -- Auras > Power Infusion Helper: NO NAV ROW, and that is the decision rather than an
    -- omission. The helper is a POOL TAB of the Aura Designer, beside My Buffs / Debuffs /
    -- Any Buff, because its records must live in the Any Buff pool -- the pool decides a
    -- record's caster filter and the helper watches OTHER people's cooldowns. It cannot be
    -- lifted out of the designer, so a second home for it could only ever be a signpost.
    -- ☠ AND A SIGNPOST IS WHAT IT WAS. The row built no page of its own: it replaced its
    -- own OnClick to jump into the designer, then called SetNavHighlight to force the
    -- sidebar to keep lighting a row the user was no longer on. Two entries for one
    -- feature, one of them lying about where you were. The tab is priest-gated, so for
    -- anyone the feature applies to it is already in front of them.
    -- ⚠ WHAT WENT WITH IT: AuraDesigner/UI/PIHelperPage.lua (the stub page and the jump),
    -- DF.BuildPIHelperPage, DF.OpenPIHelperInDesigner, and GUI.SetNavHighlight, whose only
    -- caller was that jump.
    -- ⚠ THE ONE THING LOST is a settings-SEARCH landing target: the stub page was indexed,
    -- and the designer is not. Searching the helper by name no longer lands anywhere.

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