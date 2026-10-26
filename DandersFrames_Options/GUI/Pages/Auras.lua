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
        local combatBanner = GUI:CreateInfoBanner(self.child, { dismissKey = "combat_lockout", notice = true, fontTemplate = "DFFontNormal" })

        -- A pinned "Hide from Main Frames" set puts the main frames on a name list even with
        -- sorting off (the only way a secure header can leave a member out).
        local function HidesPinnedMembers(d)
            local sets = d.pinnedFrames and d.pinnedFrames.sets
            if type(sets) ~= "table" then return false end
            for _, set in pairs(sets) do
                if type(set) == "table" and set.enabled and set.hideFromMainFrames
                   and set.frameType ~= "friendlyBoss" then
                    return true
                end
            end
            return false
        end

        -- ★ THE BANNER STATES WHICH SETTINGS USE A NAME LIST. A name-list header shows only
        -- the names on it and the list cannot change in combat, so a mid-fight joiner appears
        -- when combat ends. Self First/Last lists only the player's own group in a GROUPED
        -- raid; a flat raid and the party header put everyone on one list.
        local function UpdateCombatBanner()
            local hidesPinned = HidesPinnedMembers(db)
            if not db.sortEnabled and not hidesPinned then
                combatBanner:Hide()
                return
            end
            combatBanner:Show()

            local selfPos = db.sortSelfPosition or "SORTED"
            local sorting = db.sortEnabled
            local hasAdvancedOptions = sorting
                and (db.sortSeparateMeleeRanged or db.sortByClass or db.sortAlphabetical)
            local selfListed = sorting and (selfPos == "FIRST" or selfPos == "LAST")
            local selfListsOwnGroupOnly = GUI.SelectedMode == "raid" and db.raidUseGroups

            if hasAdvancedOptions or (selfListed and not selfListsOwnGroupOnly) then
                combatBanner:SetTone("danger")
                combatBanner:SetText(L["Combat Limitation: Players who join during combat appear when combat ends."])
            elseif hidesPinned then
                combatBanner:SetTone("danger")
                combatBanner:SetText(L["Combat Limitation: With Hide from Main Frames on, players who join during combat appear when combat ends."])
            elseif selfListed then
                combatBanner:SetTone("caution")
                -- Override default warning icon with info icon for this softer state.
                combatBanner:SetIconTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\info.png")
                combatBanner:SetText(L["Combat Limitation: Players who join your group during combat appear when combat ends."])
            else
                combatBanner:SetTone("success")
                combatBanner:SetText(L["Fully Combat Safe: Frames will update normally during combat."])
            end
        end

        -- Hidden when an external FrameSort addon owns sorting, or when nothing here puts
        -- the frames on a name list. Without the second check, the page's RefreshStates
        -- re-showed the banner after UpdateCombatBanner had hidden it -- a white, tone-less box.
        combatBanner.hideOn = function(d)
            return HideSortOptions(d) or not (d.sortEnabled or HidesPinnedMembers(d))
        end
        -- Reapply tone + text on every page refresh. RefreshStates calls
        -- refreshContent, so the banner never shows without a tone (the backdrop
        -- defaults to white until toned).
        combatBanner.refreshContent = UpdateCombatBanner
        Add(combatBanner, combatBanner.layoutHeight, "both")

        -- Initial update
        UpdateCombatBanner()
        
        -- ===== THE PAGE'S CARDS ===========================================
        -- Sorting itself down the left, the drag orders down the right:
        --
        --   column 1   Unit Frame Sorting (+ Self Position), FrameSort Integration
        --              (only with the FrameSort addon; header tick)
        --   column 2   "Priority"  Role Priority, Class Priority
        --
        -- ⚠ SELF POSITION LIVES IN UNIT FRAME SORTING: it is the first level of
        -- the very order that card describes ("Self Position > Role > Class >
        -- Name").
        --
        -- ☠ ENABLE CUSTOM SORTING STAYS IN THE BODY of the first card, as Show
        -- Debuffs does on the Debuff Bar: it is the PAGE gate. Shut, that card's
        -- corner says Off while sorting is off; the two priority cards grey their
        -- headers with it. Use FrameSort Addon is its own card's on/off, so it
        -- lives in that card's header.
        --
        -- ⚠ NO PINS ON THIS PAGE. Every card decides what ORDER frames sort in,
        -- which is behaviour, not looks.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates } and, where a toggle is hoisted, `hoistToggle`
        -- -- test_sorting_page_builders.lua pins each inventory.
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
        -- Declared above the Unit Frame Sorting card, which carries the dropdown.
        local selfPosValues = {
            ["FIRST"] = L["Always First"],
            ["LAST"] = L["Always Last"],
            ["SORTED"] = L["Sorted with Group"],
            ["NORMAL"] = L["Sorted with Group"],
            _order = {"FIRST", "LAST", "SORTED"},
        }

        -- The dropdown's callback, under a name at page scope: the card and a
        -- pinned copy drive it, and two copies of a body that repaints the combat banner is the
        -- kind of duplication that drifts one of them.
        local function ApplySelfPosition()
            TriggerSortForCurrentMode()
            UpdateCombatBanner()
        end

        -- ===== UNIT FRAME SORTING (the first card in column 1) =====
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER, so a pinned copy greys its
        -- children while custom sorting is off, exactly as the card does.
        local function BuildSortOptionsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Sort party members by role, class, and name.\n\nSort order: Self Position > Role > Class > Name"], 250), 60)

            local raidSortNote = group:AddWidget(GUI:CreateLabel(parent, L["Raid: Group layout sorts within each group.\nFlat grid layout sorts all players together."], 250), 35)
            raidSortNote.hideOn = function() return GUI.SelectedMode ~= "raid" end

            -- Built in the body: it is the PAGE gate, so no card hoists it
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
        -- body. No pin.
        Add(GUI:CreateHeader(self.child, L["Sorting"]), 40, 1)
        local band = OpenSection(L["Unit Frame Sorting"], "sorting_unitframes", 1, SortOptionsSummary)
        BuildSortOptionsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        -- ☠ SELF POSITION, at the foot of the order it heads (see the page
        -- note). Captioned "Self Position" -- "Position" alone, on a page about
        -- sorting, does not say WHOSE -- with two gates: hidden under a
        -- FrameSort takeover, and greyed with the rest of this card by the
        -- builder's group gate while custom sorting is off.
        local selfPos = band:AddWidget(GUI:CreateDropdown(self.child, L["Self Position"], selfPosValues, db, "sortSelfPosition", ApplySelfPosition), 55)
        selfPos.hideOn = HideSortOptions
        CloseSection(band)

        -- ===== FRAMESORT INTEGRATION GROUP (a card in column 1) =====
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
            -- ☠ USE FRAMESORT ADDON IS THE HEADER'S TICK; the builder skips
            -- its own (hoistToggle). Same key, label and commit. No pin.
            -- ⚠ NO SUMMARY, by decision: the tick is the whole card, and shut
            -- and off the corner already reads "Off".
            local band = OpenSection(L["FrameSort Integration"], "sorting_framesort", 1, nil, nil, nil, nil, {
                db = db, key = "useFrameSort", label = L["Use FrameSort Addon"],
                onChanged = UseFrameSortChanged,
            })
            BuildFrameSortGroup({ group = band, parent = self.child, hoistToggle = true })
            CloseSection(band)
        end

        -- ===== ROLE PRIORITY (a card under "Priority" in column 2) =====
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

        -- ===== CLASS PRIORITY (a card under "Priority" in column 2) =====
        local function BuildClassPriorityGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Drag to reorder. Top = first."], 250), 25)

            local classOrderWidget = GUI:CreateClassOrderList(parent, db, "sortClassOrder", function()
                TriggerSortForCurrentMode()
            end)
            group:AddWidget(classOrderWidget, 320)
            group.disableChildrenOn = DisableSortOptions
        end

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

        -- Also hidden while Sort by Class is off -- its variant gate.
        local band = OpenSection(L["Class Priority"], "sorting_classpriority", 2, ClassPrioritySummary,
            DisableSortOptions, function(d) return (d.useFrameSort and FrameSortApi) or not d.sortByClass end)
        BuildClassPriorityGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

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
        -- ===== COLOR PICKER =====
        -- Bound to the ACCOUNT-WIDE db, not the page's per-mode `db`. These render
        -- on both the Party and Raid tabs, and when they were per-mode the Raid copy
        -- was write-only -- the hooks only ever read party, so ticking it on Raid
        -- looked enabled and did nothing. One setting, one value, both tabs.
        local pickerDB = DF:GetGlobalDB()

        -- One card in column 1 -- each tick over the line that explains it,
        -- since a blurb takes a row of its own -- and Expand All / Collapse All
        -- at the top like every card page.
        -- No pin -- which picker opens is behaviour, not looks -- and no header
        -- tick: the two ticks are independent (see the builder's note).
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper and its two opt-ins.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- The group's four widgets, taking the group and parent they should
        -- build into.
        --
        -- ⚠ NO TOGGLE IS HOISTED. Neither tick means "am I doing anything": they
        -- are two INDEPENDENT overrides (this addon's pickers, and every other
        -- addon's), and either can be on without the other. A header tick for one
        -- would be claiming it speaks for the pair.
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

        -- Whose pickers are DF's: every addon's, this addon's only, or none
        -- (Blizzard's everywhere). The global tick wins -- it installs the
        -- hook whatever the other says.
        --
        -- ⚠ THE ACCOUNT-WIDE TABLE, NOT THE PAGE'S `db`. The card's corner is
        -- handed the per-mode table by the page pass; these two keys live in
        -- the global db, so the summary reads that instead.
        local function ColorPickerSummary()
            local g = DF:GetGlobalDB()
            if not g then return "" end
            if g.colorPickerGlobalOverride then return L["All Addons"] end
            if g.colorPickerOverride then return format(L["%s only"], "DandersFrames") end
            return L["Blizzard"]
        end

        -- ☠ THE PAGE'S TWO BULK VERBS, at col "both" -- the Debuff Bar's
        -- placement, kept on a one-card page so every card page reads alike.
        Add(tools.SectionControls(self.child), 24, "both")
        -- ⚠ NO RESET STRIP, AS BEFORE. The defaults engine answers for the
        -- per-mode tables only, and these two keys are account-wide.
        local band = OpenSection(L["Color Picker"], "integrations_colorpicker", 1, ColorPickerSummary)
        BuildColorPickerGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

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
        -- AddDispelTypeTexture binds pick up the new curve) and restyle the overlay
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

        -- A palette card's summary: "Default", or how many swatches differ from
        -- the colour their own Reset All writes back. An unseeded swatch is
        -- still the default.
        local function PaletteSummary(store, list, keyField, defaultOf)
            local n = 0
            for _, info in ipairs(list) do
                local c, d = store[info[keyField]], defaultOf(info[keyField])
                if type(c) == "table" and type(d) == "table"
                    and (math.abs((c.r or 0) - (d.r or 0)) > 0.005
                      or math.abs((c.g or 0) - (d.g or 0)) > 0.005
                      or math.abs((c.b or 0) - (d.b or 0)) > 0.005) then
                    n = n + 1
                end
            end
            if n == 0 then return L["Default"] end
            return format(L["%d custom"], n)
        end
        -- Each default is what that palette's own Reset All writes back.
        local function ClassColorsSummary()
            return PaletteSummary(classColorsDB, CLASS_LIST, "token",
                function(t) return RAID_CLASS_COLORS and RAID_CLASS_COLORS[t] end)
        end
        local function RoleColorsSummary()
            return PaletteSummary(roleColorsDB, ROLE_LIST, "token", function(t) return ROLE_DEFAULTS[t] end)
        end
        local function DispelColorsSummary()
            return PaletteSummary(dispelColorsDB, DISPEL_LIST, "key", function(k) return dispelGamePalette[k] end)
        end

        -- ===== THE PAGE'S CARDS ===========================================
        --   column 1   Class Colors, Dispel Type Colors
        --   column 2   Role Colors, Color by Time
        --
        -- ☠ EVERY KEY BEHIND THE THREE PALETTES IS A NON-PROFILE KEY.
        -- classColors / roleColors / dispelColors live at the ROOT of DF.db -- one
        -- set per profile, shared by party and raid -- and each group's own "Reset
        -- All to Default" button IS the reset story; it stays inside its card.
        --
        -- A palette's summary is "Default" or "N custom" (PaletteSummary); Color
        -- by Time has none -- see its card.
        --
        -- ⚠ THE PALETTES ARE PINNABLE (they decide how frames look); Color by Time
        -- is NOT, because every structural edit in it rebuilds the page, which
        -- would close a pinned copy (see its own note).
        --
        -- ⚠ THE TWO CROSS-LINK ANCHORS. "Dispel Type Colors" and "Color by Time"
        -- are reached from other pages through Search:ScrollToSection, which
        -- finds a page child by :GetText() -- and a card is a collapsible
        -- section, whose GetText is its title, and which the jump EXPANDS when
        -- the user had it shut.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates, popout } -- test_colors_page_builders.lua pins
        -- each inventory.
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

        -- Color by Time's column.
        local cbtColumn = 2

        -- ☠ WHAT A "RESET ALL TO DEFAULT" COSTS. The button writes every swatch
        -- in its group behind the widgets' backs, so the swatches have to be
        -- repainted -- and NOT by a page rebuild: that retires every widget on
        -- the page, the shared helper's prologue closes every open panel on the
        -- way in (so a pinned panel the button was clicked in would slam shut),
        -- and it leaks the whole page per click. The repaint is the value
        -- sweep: RefreshChildValues calls each control's `refreshValue`, which
        -- for a colour picker IS its UpdateSwatch (SettingsWidgets.lua), over
        -- the one group the button sits in; ReflowMounted(true) then runs it on
        -- every mounted pane, including a pinned copy. (The Tooltips page's
        -- AnchorGateRefresh is the same shape for the same reason.)
        local function RepaintSwatches(tools2)
            if not tools2.popout then tools2.group:RefreshChildValues() end
            tools.ReflowMounted(true)
        end

        -- ===== CLASS COLORS (the first card in column 1) =====
        --
        -- ☠ THE THIRTEEN SEEDS STAY inside the loop, ahead of the picker that
        -- reads each one. They are build-time writes to a non-profile table;
        -- moving them out would move WHEN a profile changes shape.
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

        -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
        -- Debuff Bar's placement: they act on cards in both columns.
        Add(tools.SectionControls(self.child), 24, "both")
        Add(GUI:CreateHeader(self.child, L["Unit Colors"]), 40, 1)
        -- Column 1, pinnable.
        local band = OpenSection(L["Class Colors"], "colors_class", 1, ClassColorsSummary, nil, nil, BuildClassColorsGroup)
        BuildClassColorsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ===== ROLE COLORS (the first card in column 2) =====
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

        -- Column 1 under Class Colors, pinnable.
        local band = OpenSection(L["Role Colors"], "colors_role", 1, RoleColorsSummary, nil, nil, BuildRoleColorsGroup)
        BuildRoleColorsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ===== DISPEL TYPE COLORS (the second card in column 1) =====
        -- The one palette whose commit is not a plain repaint: both callbacks
        -- live at page scope above, so the card and a pinned copy drive the same
        -- work.
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

        -- Column 2, opening Aura Colors, pinnable. Its title is the
        -- cross-link anchor the debuff Border and Dispel Overlay pages jump to
        -- (see the page note) -- keep it in step with theirs.
        Add(GUI:CreateHeader(self.child, L["Aura Colors"]), 40, 2)
        local band = OpenSection(L["Dispel Type Colors"], "colors_dispel", 2, DispelColorsSummary, nil, nil, BuildDispelColorsGroup)
        BuildDispelColorsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ===== COLOR BY TIME REMAINING (a card in column 2) =====
        -- ☠ THE ONE CARD ON THIS PAGE WITHOUT A PIN. The reasons are structural
        -- rather than taste:
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
        --      which the value sweep repaints in place; there is no such sweep for
        --      "this group now has a different list of children", and hand-rolling
        --      one here would mean reimplementing the page builder's own
        --      widget-retire loop inside a settings page.
        --
        --   2. ITS TITLE IS A CROSS-LINK ANCHOR, and a live one: every aura page
        --      and the Aura Designer reach it through UI:CreateColorsPageLink ->
        --      LinkToSetting{ page = "display_classcolors", section = the Color by
        --      Time title }. Search:ScrollToSection resolves that against the page's
        --      OWN children, and a CollapsibleSection is the one target it handles
        --      specially -- it EXPANDS the section if the user had it closed, then
        --      flashes the content rather than the 28px bar. A card IS such a
        --      section.
        --
        --   3. IT IS AN EDITOR, NOT A GROUP OF SETTINGS: unit tabs, a preview
        --      strip, a variable list of stops and a "how this renders" legend.
        --      There is no honest summary to write.
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

        -- The card's band re-sizes its rows on every layout pass; the 260px rows
        -- inside sit left-aligned in a wider card.
        --
        -- ⚠ NO SUMMARY, by decision: the card is a breakpoint editor over two
        -- ramps, and neither a count nor a list of thresholds says anything a
        -- glance can use.
        local cbtGroup = OpenSection(L["Color by Time"], "colors_bytime", cbtColumn)

        -- Tabs: which unit's stops are on the editor below. UI state only — flipping a
        -- tab changes nothing about what renders in the world. Underline-tab style
        -- (StyleButton opts.tab — the PARTY/RAID/BINDS look), half-width each so the
        -- pair spans the box. No explicit accent: the tab picks up the mode accent
        -- (party purple / raid), same as the main tabs. CreateSegmentToggle stays the
        -- compact value toggle beside a control (the s/% dials in the legend below).
        -- ⚠ EACH TAB IS ANCHORED TO ITS HALF OF THE ROW, not given a width: the box
        -- or card sizes the row, and a wide card left fixed-width tabs in its corner.
        local tabRow = CreateFrame("Frame", nil, self.child)
        tabRow:SetSize(260, 24)
        local prevTab
        for _, def in ipairs({
            { key = "SECONDS", label = L["Seconds"] },
            { key = "PERCENT", label = L["Percent"] },
        }) do
            local tabBtn = CreateFrame("Button", nil, tabRow, "BackdropTemplate")
            GUI:StyleButton(tabBtn, { tab = true, width = 128, height = 24, text = def.label, font = "DFFontHighlight" })
            tabBtn:ClearAllPoints()
            if prevTab then
                tabBtn:SetPoint("TOPLEFT", tabRow, "TOP", 2, 0)
                tabBtn:SetPoint("BOTTOMRIGHT", tabRow, "BOTTOMRIGHT", 0, 0)
            else
                tabBtn:SetPoint("TOPLEFT", tabRow, "TOPLEFT", 0, 0)
                tabBtn:SetPoint("BOTTOMRIGHT", tabRow, "BOTTOM", -2, 0)
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
        -- ⚠ THE BANDS ARE PLACED FROM THE STRIP'S LIVE WIDTH, on every size change:
        -- the editor strip is stretched to the box or card it sits in, and bands laid
        -- out once at the 256 it is built at would stay that wide in a wider card.
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
                    tex:SetColorTexture(1, 1, 1, 1)   -- white base; the gradient tints it
                    f.segs[#f.segs + 1] = { tex = tex, from = asc[k], to = asc[k + 1], lo = lo, hi = hi }
                end
            end
            local function place(width)
                width = (width and width > 0) and width or w
                for _, seg in ipairs(f.segs) do
                    seg.tex:ClearAllPoints()
                    seg.tex:SetPoint("TOPLEFT", f, "TOPLEFT", (seg.lo / maxT) * width, 0)
                    seg.tex:SetSize(((seg.hi - seg.lo) / maxT) * width, h)
                end
            end
            place(w)
            f:SetScript("OnSizeChanged", function(_, width) place(width) end)
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
                GUI:StyleButton(plus, { width = 22, height = 20, icon = { texture = iconPath .. "add.png", size = 12, color = { r = 0.85, g = 0.85, b = 0.85 } } })
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
                GUI:StyleButton(minus, { width = 22, height = 20, icon = { texture = iconPath .. "remove.png", size = 12, color = { r = 0.85, g = 0.85, b = 0.85 } } })
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
        CloseSection(cbtGroup)
        end   -- BuildSection

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

        -- ===== THE PAGE'S CARDS ===========================================
        -- Two page columns when the window is wide -- what the bar is drawn IN
        -- on the left, what it is drawn ON and the overlay on the right:
        --
        --   column 1   Color, Gradient (health colour mode Health Gradient only),
        --              Missing Health, Gradient (missing health's, same rule)
        --   column 2   Texture, Background, Reduced Max Health (header tick)
        --
        -- The cards are ADDED in reading order (Color, Texture, Gradient,
        -- Background, ...), which is also the order the one-column fold reads.
        --
        -- ☠ NO FULL-WIDTH SECTIONS OR SPACERS. Each card IS a section -- it
        -- folds and persists its fold under its own stable key -- and a
        -- full-width section or spacer is a "both" widget, a SYNC POINT that
        -- would end both columns and stack the page back into one.
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
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates } and, where a toggle is hoisted, `hoistToggle`
        -- -- test_healthbar_page_builders.lua pins each inventory.
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
        -- gradient card beside it. tools2.refreshStates covers both: on a card
        -- it is the page's own hideOn/disableOn pass (which the gradient cards'
        -- hideOn rides on), and in a pinned panel ReflowPane followed by the
        -- page's RefreshStates. No rebuild, so no AnchorGateRefresh-style branch.

        -- ===== COLOR (the first card in column 1) =====
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

        -- ===== TEXTURE (the first card in column 2) =====
        local function BuildHealthTextureGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "healthTexture",
                function() DF:UpdateAllFrames() tools2.refreshStates() end), 55)
            GUI:AddBarTileControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "health",
                { refreshStates = tools2.refreshStates })
            group:AddWidget(GUI:CreateDropdown(parent, L["Fill Direction"], orientOptions, db, "healthOrientation", function() DF:UpdateAllFrames() end), 55)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Smooth Bar Animation"], db, "smoothBars", function() DF:UpdateAllFrames() end), 30)

            GUI:AddTextureLayerControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "health",
                { baseSize = false, refreshStates = tools2.refreshStates })
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

        -- ===== GRADIENT (column 1, conditional) =====
        -- The ramp is a STOP LIST: any number of stops, each with its own
        -- threshold.
        --
        -- Modelled on the Color by Time editor further up this file, deliberately -- same
        -- preview-strip-over-rows shape, same 52px colour chip, same +/- stepper, same
        -- add/reset footer. Two editors for "a colour ramp with stops" that look
        -- different would be two things to learn.
        --
        -- ★ ONE BUILDER, BOTH BARS. The health bar and the missing-health fill each keep
        -- a stop list under this same editor; only the key prefix and the visibility
        -- rule differ. (BuildColorStops resolves <prefix>Stops first, so the legacy
        -- Low/Medium/High keys are dead on any migrated profile.)
        --
        -- ★ AND IT REBUILDS THE PAGE -- the Color by Time precedent, for the same
        -- structural reason. GradRebuild ends in pageHealthBar:Refresh(): adding
        -- a stop, removing one and committing a threshold each change which
        -- WIDGETS the editor has, and every remaining stepper's bounds are
        -- recomputed from its neighbours. There is no rebuild-one-pane verb.
        --
        -- ☠ A CARD OF ITS OWN, in column 1 under the card it belongs to, and its
        -- band IS the group every row below goes into -- so it takes no header
        -- (the card's title names the ramp) and no pin (a pinned copy would be
        -- closed by the very rebuild its + button causes). Every row, the bar and
        -- the footer are prose-shaped (no bound value), so the card's
        -- two-per-row flow gives each a row of its own; and the band re-sizes its
        -- children on every layout pass, so a stop row follows the card's width
        -- when the window folds or a resize drags it.
        --
        -- ⚠ A REBUILD FROM HERE CLOSES ANY PINNED PANEL, and that is accepted
        -- rather than fixed: the panels hold the colour/texture cards, not the
        -- ramp.
        local function BuildGradientStopBox(prefix, hideOn)
        local listKey = prefix .. "Stops"
        -- Each card names its ramp ("Health Gradient" / "Missing Health
        -- Gradient"): two cards both titled "Gradient" in one column could not be
        -- told apart. The keys are the ones they shipped with, so folds survive
        -- the rename. Hidden with its colour mode.
        -- ⚠ NO SUMMARY, by decision: a gradient stop list has no value to name,
        -- and the card only shows while its colour mode is Gradient anyway.
        local gradGroup = OpenSection((prefix == "healthColor") and L["Health Gradient"] or L["Missing Health Gradient"],
                (prefix == "healthColor") and "health_gradient" or "health_missinggradient",
                1, nil, nil, hideOn)
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
                -- ☠ CONVERT, DO NOT INVENT. Seeding Config's three-stop default here would SAVE it on a
                -- profile the migration has not reached, and because the migration is presence-gated it
                -- would then skip that profile permanently (a default profile's honest answer is FIVE
                -- stops, from Low 2 / Medium 2 / High 1). DF:LegacyStopsFor is the migration's own
                -- conversion, so the editor and the migration cannot disagree about a profile's ramp.
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
                    GUI:StyleButton(plus, { width = 22, height = 20, icon = { texture = gradIconPath .. "add.png", size = 12, color = { r = 0.85, g = 0.85, b = 0.85 } } })
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
                    GUI:StyleButton(minus, { width = 22, height = 20, icon = { texture = gradIconPath .. "remove.png", size = 12, color = { r = 0.85, g = 0.85, b = 0.85 } } })
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
        CloseSection(gradGroup)
        end

        -- ===== BACKGROUND (the second card in column 2) =====
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

        -- ===== THE HEALTH BAR CARDS' MOUNT ================================
        -- Color (1), Texture (2), the gradient editor (1), Background (2) --
        -- the order the one-column fold reads.
        --
        -- ★ BACKGROUND IN COLUMN 2, under Texture: both are what the bar is
        -- drawn ON, against Color/Gradient which are what it is drawn IN -- and
        -- the Gradient editor runs long and grows as stops are added, so column
        -- 1 already carries the weight. Missing Health (and its gradient) join
        -- column 1, Reduced Max Health joins column 2.
        local function HealthGradientHiddenOn(d) return d.healthColorMode ~= "PERCENT" end

        -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
        -- Debuff Bar's placement: they act on cards in both columns.
        Add(tools.SectionControls(self.child), 24, "both")

        -- The four looks, across both columns.
        Add(GUI:CreateHeader(self.child, L["Appearance"]), 40, "both")

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

        -- ===== MISSING HEALTH (a card in column 1) =====
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

        -- ===== REDUCED MAX HEALTH SECTION =====

        -- ===== REDUCED MAX HEALTH (a card in column 2) =====
        --
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER, so a pinned copy greys its
        -- children while the overlay is off, exactly as the card does.
        local function BuildReducedMaxHealthGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the CARD's header carries this tick.
            if not tools2.hoistToggle then
                local reducedEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable"], db, "reducedMaxHealthEnabled", function() tools2.refreshStates() DF:UpdateAllFrames() end), 30)
                reducedEnable.keepEnabled = true
            end
            group.disableChildrenOn = function(d) return not d.reducedMaxHealthEnabled end

            group:AddWidget(GUI:CreateCheckbox(parent, L["Clip Health Bar"], db, "reducedMaxHealthClipHealthBar", function() DF:UpdateAllFrames() end), 30)
            group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "reducedMaxHealthTexture", function() DF:UpdateAllFrames() tools2.refreshStates() end), 55)
            GUI:AddBarTileControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "reducedMaxHealth",
                { baseSize = true, refreshStates = tools2.refreshStates })
            group:AddWidget(GUI:CreateColorPicker(parent, L["Bar Color"], db, "reducedMaxHealthColor", true, nil, function() DF:LightweightUpdateReducedMaxHealthColor() end, true), 35)
            group:AddWidget(GUI:CreateDropdown(parent, L["Blend Mode"], reducedBlendOpts, db, "reducedMaxHealthBlendMode", function() DF:UpdateAllFrames() end), 55)

            GUI:AddTextureLayerControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "reducedMaxHealth",
                { baseSize = true, refreshStates = tools2.refreshStates })
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

        -- Its own group under the looks: an extra the bar can show, not how the
        -- bar looks. ☠ ITS ENABLE IS THE HEADER TICK (see the page note). A
        -- pin: the overlay's texture, colour and blend are how it LOOKS.
        Add(GUI:CreateHeader(self.child, L["Reduced Max Health"]), 40, "both")
        local band = OpenSection(L["Settings"], "health_reduced", 1, ReducedMaxHealthSummary, nil, nil,
            BuildReducedMaxHealthGroup)
        BuildReducedMaxHealthGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_frame", label = L["Frame"]},
            {pageId = "bars_absorbs", label = L["Absorbs"]},
        }), 30, "both")
    end)
    
    -- Bars > Resource Bar
    local pageResource = CreateSubTab("bars", "bars_resource", L["Resource Bar"])
    BuildPage(pageResource, function(self, db, Add, AddSpace, AddSyncPoint)
        Add(CreateCopyButton(self.child, {"resourceBar"}, L["Resource Bar"], "bars_resource"), 25, 2)

        -- ===== THE PAGE'S CARDS ===========================================
        -- Two page columns -- what the bar DOES on the left, how it LOOKS on the
        -- right -- under three category headers:
        --
        --   column 1   "General"  Resource Bar Settings, Class Filter
        --              "Layout"   Size, Position (+ Frame Level)
        --   column 2   "Style"    Appearance, Background (header tick), Border
        --                         (header tick), Resource Colors
        --
        -- ⚠ FRAME LEVEL LIVES IN POSITION: where the bar sits in the frame's
        -- stack is part of where the bar sits.
        --
        -- ☠ ENABLE RESOURCE BAR STAYS IN THE BODY of the first card, as Show
        -- Debuffs does on the Debuff Bar: it is the PAGE gate, and a header tick
        -- that greyed every other card would surprise people. Shut, that card's
        -- corner says Off while the bar is off. Show Background and Show Border are
        -- their own cards' on/off, so they live in those cards' headers.
        --
        -- ⚠ THE PAGE GATE GREYS EVERY OTHER CARD: its header through dimOn, its
        -- controls through the group gate each builder carries.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates } and, where a toggle is hoisted, `hoistToggle`
        -- -- test_resourcebar_page_builders.lua pins each inventory.
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
        -- The cards print the chosen value as their SUMMARY, written OUTSIDE the group's builder,
        -- so the word has to come from the same table the dropdown offers, or a card could say one
        -- thing while the control behind it says another.
        --
        -- ⚠ THE CLASS LIST LIVES HERE BUT THE SEED DOES NOT. The `db.resourceBarClassFilter`
        -- seeding block that reads it stays inside the builder, where it runs at page-build time;
        -- moving it would move WHEN a profile changes shape, which the export byte-identity gate
        -- measures.
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

        -- ===== SETTINGS (the first card under "General") =====
        --
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER, as it does for every group on
        -- this page, so a card and a pinned panel grey alike while the bar is off.
        local function BuildResourceSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Built in the body: it is the PAGE gate, so no card hoists it
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

        -- ===== CLASS FILTER (the second card under "General") =====
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

        -- ===== SIZE (the first card under "Layout") =====
        -- ★ THE CONTROLS RENAME THEMSELVES BY ORIENTATION. resourceBarWidth and resourceBarHeight
        -- are ORIENTATION-RELATIVE keys: Width is the bar's LENGTH along its fill axis, Height its
        -- THICKNESS across it, and Bars.lua swaps them onto screen axes for a vertical bar. Match
        -- always pins the LENGTH, so the checkbox and the slider it greys must carry the same
        -- word in each orientation ("Match Health Bar Height" greys "Height"), and the free slider
        -- is always "Thickness".
        --
        -- ⚠ The rename rides refreshContent (RefreshStates' dynamic-content hook), so it follows
        -- the Orientation dropdown, a profile import and a copy-from-other-mode alike -- anything
        -- that ends in RefreshStates; the Orientation dropdown's callback calls RefreshStates for
        -- that reason.
        --
        -- ⚠ THE HOOK ALSO FIRES IN A PINNED PANEL: refreshContent is run by DandersUI Sections'
        -- RefreshChildStates, which ReflowPane calls on the group it re-flows, so
        -- tools2.refreshStates renames these two controls in a panel as self:RefreshStates does on
        -- the page. A refresh driven from the page does NOT reach a panel, which is why the
        -- Orientation dropdown has its own note.
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
            -- border -- an option whose two states can render the
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

        -- ===== POSITION (the second card under "Layout", where Frame Level
        -- joins it) =====
        local function BuildResourcePositionGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "resourceBarAnchor", function() DF:UpdateAllFrames() end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -50, 50, 1, db, "resourceBarX", nil, function() DF:LightweightUpdatePowerBarPosition() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -50, 50, 1, db, "resourceBarY", nil, function() DF:LightweightUpdatePowerBarPosition() end, true), 55)
        end

        -- ☠ THE POSITION CARD: the builder above, then Frame Level (see the page
        -- note). ONE function for the card AND its pin, so a pinned Position
        -- panel ends in the slider too. Two callback slots (nothing on commit,
        -- the frame-level reapply on the drag tick) and the shared tooltip; the
        -- builder's group gate greys it with the rest of Position.
        local function BuildResourcePositionCardGroup(tools2)
            BuildResourcePositionGroup(tools2)
            tools2.group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(tools2.parent, L["Frame Level"], 0, 100, 1, db, "resourceBarFrameLevel", nil, function() DF:LightweightUpdateResourceBarFrameLevel() end, true)), 55)
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

        -- ===== APPEARANCE (the first card under "Style") — mirrors the Health
        -- Bar's Texture group: Texture, Orientation / Reverse Fill, and Smooth
        -- Bar Animation in one place. =====
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
        local function OrientationChanged(tools2)
            tools2.refreshStates()
            tools.ReflowMounted()
        end

        local function BuildResourceAppearanceGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group.disableChildrenOn = function(d) return not d.resourceBarEnabled end

            group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "resourceBarTexture", function() DF:UpdateAllFrames() tools2.refreshStates() end), 55)
            GUI:AddBarTileControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "resourceBar",
                { refreshStates = tools2.refreshStates })

            group:AddWidget(GUI:CreateDropdown(parent, L["Orientation"], orientOptions, db, "resourceBarOrientation", function()
                -- RefreshStates so the Size controls rename to the new orientation at once
                -- (their refreshContent hooks — see the Size group).
                OrientationChanged(tools2)
                DF:UpdateAllFrames()
            end), 55)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Reverse Fill Direction"], db, "resourceBarReverseFill", function() DF:UpdateAllFrames() end), 30)

            group:AddWidget(GUI:CreateCheckbox(parent, L["Smooth Bar Animation"], db, "resourceBarSmooth", function() DF:UpdateAllFrames() end), 30)

            GUI:AddTextureLayerControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "resourceBar",
                { baseSize = false, refreshStates = tools2.refreshStates })
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

        -- ===== BACKGROUND (the second card under "Style") =====
        --
        -- ⚠ SHOW BACKGROUND IS THE CARD'S HEADER TICK (hoistToggle), so the
        -- card's body is the one colour swatch it gates.
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

        -- ===== BORDER (the third card under "Style") =====
        -- Include set tailored for a resource indicator:
        -- alpha / inset / blendMode / gradient / shadow keep the visual
        -- toolkit; classColor / roleColor match the bar's optional class
        -- tinting (resourceBarClassColor) for cohesion. Skipped: animate
        -- (resource bar is decoration, not an alert surface), offset (bar
        -- has its own X/Y positioning controls above), colorByTime /
        -- colorByType (no aura-state context).
        --
        -- ⚠ noShowToggle IS THE HOIST. With it the built-in Show Border checkbox
        -- is not built and the card's header carries that tick instead; showKey
        -- is still read, so borderOff still greys the other sixteen.
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
                -- every widget's own predicate.
                disableWhen  = ResourceOffRow,
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

        -- ===== RESOURCE COLORS (the last card under "Style") =====
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
                -- ☠ A VALUE SWEEP, NOT A PAGE REBUILD -- the Colors page's
                -- RepaintSwatches, same reason. The button writes ten swatches
                -- behind the widgets' backs, so they have to be repainted; a
                -- rebuild would retire every widget on the page and the prologue
                -- would close every open panel on the way in. RefreshChildValues
                -- calls each control's `refreshValue`, which for a colour picker is
                -- its swatch update, and ReflowMounted(true) runs it on every
                -- mounted pane including a pinned copy.
                if not tools2.popout then group:RefreshChildValues() end
                tools.ReflowMounted(true)
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
        -- Settings, Class Filter, Size, Position (+ Frame Level) in column 1;
        -- Appearance, Background, Border and Resource Colors in column 2 -- the
        -- order the one-column fold reads.
        -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
        -- Debuff Bar's placement: they act on cards in both columns.
        Add(tools.SectionControls(self.child), 24, "both")
        -- The category header the two General cards sit under.
        Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)
        -- ☠ NO TICK: Enable Resource Bar is the page gate and stays in the body
        -- (see the page note). No pin: which roles get a bar is behaviour, not
        -- looks.
        local band = OpenSection(L["Settings"], "resource_settings", 1, ResourceSettingsCardSummary)
        BuildResourceSettingsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- Thirteen class ticks, two per row on a wide card. No pin: which
        -- classes get a bar is behaviour. Greys its header with the page gate.
        local band = OpenSection(L["Class Filter"], "resource_classfilter", 1, ResourceClassFilterSummary, ResourceOffRow)
        BuildResourceClassFilterGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        Add(GUI:CreateHeader(self.child, L["Layout"]), 40, 1)
        -- A pin: the bar's length and thickness are how it LOOKS.
        local band = OpenSection(L["Size"], "resource_size", 1, ResourceSizeSummary, ResourceOffRow, nil,
            BuildResourceSizeGroup)
        BuildResourceSizeGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- A pin: where the bar sits is how it LOOKS. Card and pin both mount
        -- the card builder, so both end in Frame Level.
        local band = OpenSection(L["Position"], "resource_position", 1, ResourcePositionSummary, ResourceOffRow, nil,
            BuildResourcePositionCardGroup)
        BuildResourcePositionCardGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- The category header the four Style cards sit under.
        Add(GUI:CreateHeader(self.child, L["Appearance"]), 40, 2)
        local band = OpenSection(L["Bar Style"], "resource_appearance", 2, ResourceAppearanceSummary, ResourceOffRow, nil,
            BuildResourceAppearanceGroup)
        BuildResourceAppearanceGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ☠ SHOW BACKGROUND IS THE HEADER'S TICK; the builder skips its own
        -- (hoistToggle). The commit is what the in-body checkbox ran, plus a
        -- reflow for a pinned copy -- never a page rebuild. It greys with the
        -- page gate. Shown and shut, the corner gives the colour's alpha --
        -- the one number in a card whose other control is a swatch.
        local function ResourceBackgroundSummary(d)
            local c = d and d.resourceBarBackgroundColor
            if type(c) ~= "table" then return "" end
            return format("%s %.2f", L["Alpha"], tonumber(c.a) or 1)
        end
        local band = OpenSection(L["Background"], "resource_background", 2, ResourceBackgroundSummary, ResourceOffRow, nil,
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

        -- A pin: which colour each bar is drawn in is how it LOOKS.
        local band = OpenSection(L["Resource Colors"], "resource_colors", 2, ResourceColorsSummary, ResourceOffRow, nil,
            BuildResourceColorsGroup)
        BuildResourceColorsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)
    end)
    
    -- Bars > Absorbs (combined Absorb Shield + Heal Absorb with collapsible sections)
    local pageAbsorb = CreateSubTab("bars", "bars_absorb", L["Absorbs"])
    BuildPage(pageAbsorb, function(self, db, Add, AddSpace)
        Add(CreateCopyButton(self.child, {"absorbBar", "healAbsorb"}, L["Absorbs"], "bars_absorb"), 25, 2)

        -- ===== THE PAGE'S CARDS ===========================================
        -- ONE card per bar, and the two cards sit SIDE BY SIDE, one per page
        -- column, when the window is wide enough (testers compared the two bars
        -- and did not want to scroll between them):
        --
        --   column 1   Absorb Shield
        --   column 2   Heal Absorb
        --
        -- ☠ NO FULL-WIDTH SECTION OR SPACER between the two cards: it would push
        -- Heal Absorb under Absorb Shield. test_absorbs_page_builders.lua pins
        -- each builder's inventory.
        --
        -- ⚠ NEITHER CARD CARRIES A TICK. There is no enable key for either bar --
        -- the Display Mode dropdown IS the master, and neither list of modes has an
        -- off. Both are pinnable: every control in them decides how a bar looks.
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

        -- ===== ABSORB SHIELD (the first card, column 1) =====
        --
        -- ⚠ THE STRIPE MERGE STAYS INSIDE THE BUILDER. It augments the option table
        -- the dropdown is about to be handed, which is the builder's own business;
        -- moving it out would put a page-scope table in front of two dropdowns that
        -- have always had one each.
        --
        -- ⚠ AND SO DOES THE "Floating Bar Position" HEADER, on a row of its own:
        -- FLOATING mode shows fourteen controls in one stack and the header is
        -- what says where the general four stop and the nine floating ones
        -- begin. It hides with them in every other mode.
        local function BuildAbsorbShieldGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local function add(w, h) return group:AddWidget(w, h) end

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
            add(GUI:CreateTextureDropdown(parent, L["Texture"], db, "absorbBarTexture", function() DF:UpdateAllFrames() tools2.refreshStates() end, textureOptions), 55, 1)
            GUI:AddBarTileControls(function(w, h) return add(w, h, 1) end, parent, db, "absorbBar",
                { baseSize = true, refreshStates = tools2.refreshStates })

            add(GUI:CreateColorPicker(parent, L["Bar Color"], db, "absorbBarColor", true, nil, function() DF:LightweightUpdateAbsorbBarColor() end, true), 35, 1)

            local blendOptions = { BLEND= L["Normal (BLEND)"], ADD= L["Additive (ADD)"] }
            add(GUI:CreateDropdown(parent, L["Blend Mode"], blendOptions, db, "absorbBarBlendMode", function() DF:UpdateAllFrames() end), 55, 1)

            local overlayRev = add(GUI:CreateCheckbox(parent, L["Reverse Overlay Fill"], db, "absorbBarOverlayReverse", function() DF:UpdateAllFrames() end), 25, 1)
            overlayRev.hideOn = function(d) return d.absorbBarMode ~= "OVERLAY" and d.absorbBarMode ~= "ATTACHED_OVERFLOW" end

            local absorbShowOvershield = add(GUI:CreateCheckbox(parent, L["Show Overshield Glow"], db, "absorbBarShowOvershield", function() DF:UpdateAllFrames() end), 25, 1)
            absorbShowOvershield.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
            absorbShowOvershield.tooltip = L["Shows a glow at the end of the health bar when the absorb is bigger than the missing health."]

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

            GUI:AddTextureLayerControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "absorbBar",
                { baseSize = true, refreshStates = tools2.refreshStates })
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

        -- ===== HEAL ABSORB (the second card, column 2) =====
        --
        -- ⚠ THE BLURB TRAVELS WITH THE CONTROLS. It says what a heal absorb IS,
        -- which is the one thing a user opening this card may not know, so it is
        -- the group's first widget, on a row of its own.
        local function BuildHealAbsorbGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local function add(w, h) return group:AddWidget(w, h) end

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
            add(GUI:CreateTextureDropdown(parent, L["Texture"], db, "healAbsorbBarTexture", function() DF:UpdateAllFrames() tools2.refreshStates() end, healTextureOptions), 55, 1)
            GUI:AddBarTileControls(function(w, h) return add(w, h, 1) end, parent, db, "healAbsorbBar",
                { baseSize = true, refreshStates = tools2.refreshStates })

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

            GUI:AddTextureLayerControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "healAbsorbBar",
                { baseSize = true, refreshStates = tools2.refreshStates })
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

        -- Column 2, beside Absorb Shield when the window is wide. Pinnable.
        local band = OpenSection(L["Heal Absorb"], "absorbs_healabsorb", 2, HealAbsorbSummary, nil, nil,
            BuildHealAbsorbGroup)
        BuildHealAbsorbGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

    end)
    
    -- Bars > Heal Prediction
    local pageHealPrediction = CreateSubTab("bars", "bars_healpred", L["Heal Prediction"])
    BuildPage(pageHealPrediction, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"healPrediction"}, L["Heal Prediction"], "bars_healpred"), 25, 2)

        -- ===== THE PAGE'S CARDS ===========================================
        -- Two page columns -- what the bar is and does on the left, where a
        -- floating bar sits on the right:
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
        -- (OpenSection's hideFn). The Display Mode pick makes the two floating
        -- cards appear and disappear through the page's own state pass.
        --
        -- ⚠ THE PAGE GATE GREYS THE TWO FLOATING HEADERS (dimOn). Their controls
        -- grey on their own: every widget here carries `disableOn = not
        -- healPredictionEnabled`, inside the builders.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking { group,
        -- parent, refreshStates } -- test_healpred_page_builders.lua pins each
        -- inventory.
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

        -- The two predicates the page turns on. The gate only greys the cards'
        -- HEADERS: the controls already grey, one by one, inside the builders.
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

        -- ===== SETTINGS (the first card in column 1) =====
        --
        -- ☠ ALL THREE COLOUR PICKERS ARE BUILT, gated by hideOn on the source
        -- mode: Split shows the mine and others pickers, every other mode the
        -- one colour it uses. The widget set never changes, so the Show Heals
        -- From callback needs nothing more than the state pass -- a page rebuild
        -- to rebind a picker would close a pinned panel the dropdown was clicked
        -- in -- and all three colours stay findable by search whatever the mode.
        local function BuildHealPredictionSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the card's header carries this tick.
            if not tools2.hoistToggle then
                local hpEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Heal Prediction"], db, "healPredictionEnabled", function()
                    tools2.refreshStates()
                    DF:UpdateAllFrames()
                end), 30)
                hpEnable.keepEnabled = true
            end

            local overhealCheckbox = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Overheal"], db, "healPredictionShowOverheal", function() DF:UpdateAllFrames() end), 30)
            overhealCheckbox.disableOn = function(d) return not d.healPredictionEnabled end
            overhealCheckbox.tooltip = L["When enabled, a spark at the end of the health bar shows when incoming heals would overheal."]

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
                -- All three pickers already exist, so there is nothing to
                -- rebind -- and a rebuild would close a pinned panel this
                -- dropdown may have been clicked in.
                tools2.refreshStates()
                DF:UpdateAllFrames()
            end), 55)
            showModeDropdown.disableOn = function(d) return not d.healPredictionEnabled end
            showModeDropdown.tooltip = L["Which incoming heals the bar shows: all sources, only yours, or only from others."]

            local textureOptions = DF:GetTextureList()
            local texDropdown = group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "healPredictionTexture", function() DF:UpdateAllFrames() tools2.refreshStates() end, textureOptions), 55)
            texDropdown.disableOn = function(d) return not d.healPredictionEnabled end
            GUI:AddBarTileControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "healPrediction",
                { baseSize = true, refreshStates = tools2.refreshStates,
                  disableOn = HealPredOffRow })

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

            local blendOptions = { BLEND= L["Normal (BLEND)"], ADD= L["Additive (ADD)"] }
            local blendDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Blend Mode"], blendOptions, db, "healPredictionBlendMode", function() DF:UpdateAllFrames() end), 55)
            blendDropdown.disableOn = function(d) return not d.healPredictionEnabled end

            GUI:AddTextureLayerControls(function(w, h) return group:AddWidget(w, h) end, parent, db, "healPrediction",
                { baseSize = true, refreshStates = tools2.refreshStates })
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

        -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
        -- Debuff Bar's placement: they act on cards in both columns.
        Add(tools.SectionControls(self.child), 24, "both")
        -- ☠ NO TICK: Enable Heal Prediction is the page gate and stays in the
        -- body (see the page note). Shut, the corner says Off while the bar is
        -- off, else the mode and the source.
        --
        -- A pin: the texture, the colours and the blend are how the bar LOOKS.
        Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)
        local band = OpenSection(L["Settings"], "healpred_settings", 1, HealPredictionCardSummary, nil, nil,
            BuildHealPredictionSettingsGroup)
        BuildHealPredictionSettingsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ===== FLOATING BAR POSITION (the first card in column 2) =====
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

        -- ☠ COLUMN 2, HIDDEN UNLESS THE BAR FLOATS -- header and band together.
        -- Greys its header with the page gate; its controls grey themselves.
        -- A pin: size and fill direction are how the bar LOOKS.
        -- Layout heads column 2 and hides with its two cards unless the bar floats.
        local layoutHeader = GUI:CreateHeader(self.child, L["Layout"])
        layoutHeader.hideOn = HealPredFloatingHiddenOn
        Add(layoutHeader, 40, 2)
        local band = OpenSection(L["Floating Bar Position"], "healpred_floating", 2, HealPredictionFloatingSummary,
            HealPredOffRow, HealPredFloatingHiddenOn, BuildHealPredictionFloatingGroup)
        BuildHealPredictionFloatingGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ===== FLOATING BAR ANCHOR (the second card in column 2) =====
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

        -- Under Floating Bar Position, on the same two gates: same bar, same
        -- mode. A pin: where the bar sits and its colour are how it LOOKS.
        local band = OpenSection(L["Floating Bar Anchor"], "healpred_anchor", 2, HealPredictionAnchorSummary,
            HealPredOffRow, HealPredFloatingHiddenOn, BuildHealPredictionAnchorGroup)
        BuildHealPredictionAnchorGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)
    end)
    
    -- ========================================
    -- CATEGORY: Text
    -- ========================================
    CreateCategory("text", L["Text"])
    
    -- Text > Text Designer
    local pageTextDesigner = CreateSubTab("text", "text_designer", L["Text Designer"])
    -- ONE BUILD, NOT ONE PER MODE (page.singleModeBuild -- see ONE RETAINED BUILD PER
    -- MODE in GUI/Panel.lua): rebuilt on every party/raid switch, as before.
    -- The designer keeps its own state beside the build (page.dfTD, its own
    -- island outside page.children, a swapped-in RefreshStates), none of which
    -- a second retained build could share.
    if pageTextDesigner then pageTextDesigner.singleModeBuild = true end
    -- The designer builds its own island, anchored inside frames of its own;
    -- the harness's Add and AddSpace are handed over but not used.
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
    -- the _fd* verbs, its spacer) that one page can
    -- only hold for one build.
    if pageFilterDesigner then pageFilterDesigner.singleModeBuild = true end
    BuildPage(pageFilterDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        -- ☠ THE HELPER'S SWEEP RUNS HERE TOO. It marks the Power Infusion Helper's seeded lists as
        -- CURATED (dfDefaults), which gives their rows the on/off tick instead of the destructive ✕
        -- and puts Reset on screen; someone inspecting that list may open the Filter Designer
        -- before the Aura Designer ever builds.
        -- ⚠ A MIGRATION HOOK, not a dependency: schema-stamped, so it is one comparison after the
        -- first run, and priest-gated so it costs nothing for anyone else.
        if DF.IsPIHelperAvailable and DF.IsPIHelperAvailable()
            and DF.AuraDesigner and DF.AuraDesigner._priv
            and DF.AuraDesigner._priv.PIH_Sweep then
            DF.AuraDesigner._priv.PIH_Sweep()
        end
        -- ⚠ MIRRORED IN DF.SECTION_PREFIXES.auras_filterdesigner (GUI.lua) -- change both.
        -- ☠ THIS PAGE OWNS NO PER-MODE KEYS, and its Copy/Sync/Reset list is deliberately EMPTY:
        -- buffFilterSelection and directBuff* belong to Buff Bar, the debuff filters and blacklist
        -- to Debuff Bar. A page's Sync/Reset must own EXACTLY the keys it displays, or Reset Page
        -- on the filter library would rewrite two other pages' settings.
        -- What this page edits is not per-mode at all: preset overrides are per PROFILE and custom
        -- filters per ACCOUNT, so neither is something Copy to Raid or Sync with Raid can act on.
        -- ⚠ Still CALLED with an empty list, because the call registers this page in
        -- DF.SectionRegistry -- as owning nothing, or SectionOwnsKey would fall through to another
        -- page's prefix and hand these keys back. The helper returns a zero-height placeholder for
        -- an empty list, so no dead Copy/Sync/Reset row is drawn.
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
    -- The designer builds its own island, anchored inside one frame of its
    -- own; the harness's Add and AddSpace are handed over but not used.
    BuildPage(pageAuraDesigner, function(self, db, Add, AddSpace, AddSyncPoint)
        if DF.BuildAuraDesignerPage then
            DF.BuildAuraDesignerPage(GUI, self, db, Add, AddSpace)
        end
    end)

    -- Auras > Power Infusion Helper: NO NAV ROW, by decision. The helper is a POOL TAB of the
    -- Aura Designer, beside My Buffs / Debuffs / Any Buff, because its records must live in the
    -- Any Buff pool (the pool decides a record's caster filter, and the helper watches OTHER
    -- people's cooldowns). The tab is priest-gated, so for anyone the feature applies to it is
    -- already in front of them; a second nav entry could only be a signpost. The cost: the
    -- settings search has no landing target for the helper by name.

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