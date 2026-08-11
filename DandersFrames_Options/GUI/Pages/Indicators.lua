-- Part 4 of the settings pages, split from Options.lua.
-- The parts run as a chain so the pages build in their original order.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local format = string.format
function DF._SetupGUIPagesPart4(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
    BuildPage(pageBuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- ☠ NO "where this bar's contents come from" BANNER, and do not re-add one.
        -- There was one, listing the filters feeding this bar with a link off to go
        -- choose them, and it existed only because the choosing happened on another
        -- page. It does not any more: the Buff Filters group below IS the answer, in
        -- full, with a Manage Filters button for the one thing it cannot do. A banner
        -- pointing at a control six inches beneath it is noise.

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

        -- ========================================
        -- AD DISCOVERY BANNER
        -- The INVERSE of the coexistence banner above: shown only when the Aura
        -- Designer is NOT active, to point users who want more than one look for
        -- every buff at per-slot control + advanced indicators. Its hideOn is the
        -- exact negation of adBanner's, so precisely one AD banner ever occupies
        -- this slot (a hidden banner collapses to zero height — no gap).
        -- success tone (an inviting green), but a "widget" glyph overrides the tone's
        -- default check so it reads as "advanced indicators available", not a
        -- completed-state confirmation. Reuses adLink/adOnLink (the openAD path).
        -- ========================================
        local adPromoBanner = GUI:CreateInfoBanner(self.child, {tone = "success"})
        adPromoBanner:SetIconTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\widget_small")
        adPromoBanner.refreshContent = function(b)
            b:SetHTML(L["The buff bar shows auras. The Aura Designer makes the frame react to them — recolour the health bar, ring the frame, flash a corner icon, play a sound. Per spell, or per filter."] .. " " ..
                adLink("openAD", L["Open Aura Designer"]), adOnLink)
        end
        adPromoBanner.hideOn = function(d)
            local _adCfg = DF.GetModeAuraDesigner and DF:GetModeAuraDesigner((d == DF.db.raid) and "raid" or "party")
            return (_adCfg and _adCfg.enabled) and true or false   -- hide when AD IS active
        end
        Add(adPromoBanner, 32, "both")

        -- Copy button at top right
        -- "directBuff" covers the Order & Limits sort keys (directBuffSortOrder /
        -- SortMineFirst / SortReverse) — they do not start with "buff", so they were
        -- owned by no section and skipped by Copy, Sync and Reset alike.
        -- ⚠ buffFilterSelection joined this list when the filter group moved here.
        -- "directBuff" already prefix-matched directBuffShowAll / directBuffOnlyMine,
        -- but the selection TABLE does not start with any of these prefixes and had
        -- to be named outright — a page's Sync/Reset must own exactly the keys it
        -- shows, and this page now shows that table.
        Add(CreateCopyButton(self.child, {"buff", "showBuffs", "directBuff", "buffFilterSelection"}, L["Buff Bar"], "auras_buffs"), 25, 2)

        -- ===== BUFF FILTERS (Column 1, first) =====
        -- WHICH auras reach this bar, moved here from the Aura Filters page so that
        -- every consumer picks its own filters in its own place and Aura Filters is
        -- purely where filters are BUILT. The Defensive Icon has always worked this
        -- way; this makes the buff bar match it instead of being the one exception.
        --
        -- It sits first in column 1, above Deduplication and Settings: it decides
        -- what the bar contains, and everything else on the page decides how that
        -- content looks.
        --
        -- ⚠ The rows are the same three kinds the Aura Filters page listed, in the
        -- same order: built-in presets, then custom filters, then the complement
        -- bucket. Reordering them here would make the two pages disagree about what
        -- the library looks like.
        do
            local R = DF.FilterRegistry
            local filterGroup = GUI:CreateSettingsGroup(self.child, 280)
            filterGroup:AddWidget(GUI:CreateHeader(self.child, L["Buff Filters"]), 40)

            -- ⚠ NEVER reassign buffFilterSelection or its inner tables: the aura
            -- pipeline holds references to them and a fresh table strands every
            -- holder. Create-if-missing, then mutate in place.
            local function BuffSelection()
                local mdb = DF.db and DF.db[GUI.SelectedMode or "party"]
                if not mdb then return nil end
                mdb.buffFilterSelection = mdb.buffFilterSelection or {}
                local sel = mdb.buffFilterSelection
                sel.presets = sel.presets or {}
                sel.customs = sel.customs or {}
                return sel
            end
            -- Rebuild the native filter strings and re-drive the container rows --
            -- the same pair the Aura Filters page ran on every tick, and the same
            -- one the Defensive Icon group above uses.
            local function BuffFilterChanged()
                if DF.RebuildDirectFilterStrings then DF:RebuildDirectFilterStrings() end
                if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            end
            -- All Buffs overrides the whole list, so every row below it greys while
            -- it is on -- the same relationship the two had on the old page.
            local function ShowAllOn() return (db.directBuffShowAll) and true or false end

            local showAllCb = filterGroup:AddWidget(GUI:CreateCheckbox(self.child, L["All Buffs"], db, "directBuffShowAll", function()
                self:RefreshStates()
                BuffFilterChanged()
            end), 30)
            showAllCb.tooltip = L["All Buffs"]
            showAllCb.tooltipDesc = L["Show every buff with no filtering."]

            local onlyMineCb = filterGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Only My Buffs"], db, "directBuffOnlyMine", function()
                BuffFilterChanged()
            end), 30)
            onlyMineCb.tooltip = L["Only My Buffs"]
            onlyMineCb.tooltipDesc = L["Only show buffs that you cast. Applies to all buff filters."]

            -- ⚠ A rule between the two SCOPE switches above and the filter list below.
            -- They are not filters: All Buffs overrides the whole list and Only My
            -- Buffs modifies all of it, so sharing the list's row height and checkbox
            -- made them read as two more filters you could pick. The old page drew its
            -- own divider for exactly this; this is the same fix with the shared
            -- widget (GUI:CreateSeparator, lifted out of the Blizzard Frames group).
            filterGroup:AddWidget(GUI:CreateSeparator(self.child), 14)

            -- ⚠ BELOW the rule, not under the header. This sentence is about how the
            -- FILTER ROWS combine, and above the rule it sat over the two scope
            -- switches -- which do not combine with anything and are precisely what
            -- the rule separates out. A caption describing a list belongs inside that
            -- list's half of the group.
            --
            -- (The Defensive Icon's copy of this line does sit under its header, and
            -- correctly: that group has no scope switches, so its header and its rows
            -- are already adjacent.)
            filterGroup:AddWidget(GUI:CreateLabel(self.child,
                "|cff888888" .. L["Selected filters are combined — a buff matching any of them is shown."] .. "|r", 250), 35)

            local function SelectionCheckbox(labelText, getSel, setSel)
                local cb = filterGroup:AddWidget(GUI:CreateCheckbox(self.child, labelText, nil, nil,
                    BuffFilterChanged, getSel, setSel), 30)
                cb.disableOn = ShowAllOn
                return cb
            end

            for _, cat in ipairs(R.Categories) do
                local key = cat.key
                local enabled, total = R:PresetCounts(key)
                local counts = R:IsPresetModified(key)
                    and format("(%d/%d, %s)", enabled, total, L["Modified"])
                    or  format("(%d/%d)", enabled, total)
                SelectionCheckbox(format("%s |cff888888%s|r", L[cat.name], counts),
                    function() local s = BuffSelection(); return (s and s.presets[key]) or false end,
                    function(v) local s = BuffSelection(); if s then s.presets[key] = v or nil end end)
            end

            -- Custom filters, name-sorted for a stable order (the store is id-keyed).
            local sortedCustoms = {}
            for cfId in pairs(R:ReadStore().customFilters) do
                sortedCustoms[#sortedCustoms + 1] = cfId
            end
            table.sort(sortedCustoms, function(a, b)
                local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
                local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
                if na ~= nb then return na < nb end
                return a < b
            end)
            for _, cfId in ipairs(sortedCustoms) do
                local f = R:GetCustomFilter(cfId)
                SelectionCheckbox(format("%s |c%s(%s)|r", f.name or cfId, GUI:ToneHex("info"), L["Custom"]),
                    function() local s = BuffSelection(); return (s and s.customs[cfId]) or false end,
                    function(v) local s = BuffSelection(); if s then s.customs[cfId] = v or nil end end)
            end

            -- The complement bucket: buffs in no category at all.
            local uncatCb = SelectionCheckbox(L["Uncategorised Buffs"],
                function() local s = BuffSelection(); return (s and s.uncategorised) or false end,
                function(v) local s = BuffSelection(); if s then s.uncategorised = v and true or false end end)
            uncatCb.tooltip = L["Uncategorised Buffs"]
            uncatCb.tooltipDesc = L["Buffs that belong to none of the filters above."]

            -- ⚠ THE PAGE'S ONLY FEEDBACK LOOP above the frame level. Everything above
            -- this line says what you switched ON; nothing said what that adds up to,
            -- so a working selection and an empty one looked identical until you
            -- joined a group. The Filter Designer's tab strip used to carry this
            -- number and lost it when the tabs went; it belongs here now, beside the
            -- switches that move it.
            --
            -- ⚠ R:CountSelection, NOT the size of ResolveSelection's map: that map is
            -- keyed by spell ID and one record can carry several, so counting it
            -- reports roughly triple. It returns nil when the total is unbounded --
            -- All Buffs on, nothing selected, or Uncategorised Buffs, which admits
            -- auras the registry has never seen -- and this prints "All" rather than
            -- inventing a number for those.
            -- ⚠ The explicit slot height is deliberate. It stamps _slotHeightExplicit,
            -- which keeps CreateLabel's deferred height-converge (and the RelayoutHost
            -- it can fire) out of the picture for a one-line label that never wraps.
            --
            -- ⚠ Deduped on the rendered string. CreateLabel:SetText re-measures and
            -- schedules a C_Timer every call, and refreshContent runs on EVERY
            -- RefreshStates pass -- so writing unconditionally would queue a timer per
            -- refresh for a string that changes only when you tick something.
            local countLabel = filterGroup:AddWidget(GUI:CreateLabel(self.child, "", 250), 24)
            countLabel.refreshContent = function(w, d)
                local text
                if d.directBuffShowAll then
                    text = L["Tracking every buff."]
                else
                    local n = R.CountSelection and R:CountSelection(d.buffFilterSelection)
                    text = n and format(L["Tracking %d auras."], n) or L["Tracking every buff."]
                end
                if w._dfCountText ~= text then
                    w._dfCountText = text
                    w:SetText("|cff8a8f9f" .. text .. "|r")
                end
            end

            local manageBtn = filterGroup:AddWidget(GUI:CreateButton(self.child, L["Manage Filters"], 140, 22, function()
                if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
                    GUI.SelectTab("auras_filterdesigner")
                end
            end), 30)
            manageBtn.disableOn = function() return not (GUI.Pages and GUI.Pages["auras_filterdesigner"]) end

            -- This page's build is cached across tab switches, but preset counts and
            -- the custom-filter list change on the Aura Filters page while this one
            -- is hidden. Invalidate on show when the registry signature moved, so
            -- the rows rebuild instead of serving a stale list. Same idiom, and the
            -- same reason, as the Defensive Icon group.
            local function RegistrySignature()
                local parts = {}
                for _, cat in ipairs(R.Categories) do
                    local enabled, total = R:PresetCounts(cat.key)
                    parts[#parts + 1] = format("%s:%d/%d%s", cat.key, enabled, total,
                        R:IsPresetModified(cat.key) and "*" or "")
                end
                for cfId, f in pairs(R:ReadStore().customFilters) do
                    parts[#parts + 1] = cfId .. "=" .. (f.name or "")
                end
                table.sort(parts)
                return table.concat(parts, ";")
            end
            self.dfBuffFilterSignature = RegistrySignature()
            if not self.dfBuffFilterSigHooked then
                self.dfBuffFilterSigHooked = true
                self:HookScript("OnShow", function(page)
                    if page.dfBuffFilterSignature ~= RegistrySignature() then
                        page:Invalidate()
                    end
                end)
            end

            Add(filterGroup, nil, 1)
        end

        -- ===== ORDER & LIMITS (Column 1, under the filters) =====
        -- ⚠ MOVED UP FROM THE FOOT OF THE PAGE. Within a column the Add() order IS
        -- the layout order, so this block had to move bodily -- there is no insert-at.
        --
        -- It belongs directly under the filters because it is the second half of one
        -- question: the filters decide WHICH buffs qualify, these decide how many of
        -- them you get and in what order. Sitting eight boxes apart, below Position
        -- and Border, Order & Limits read as a styling option.
        --
        -- Neither of these IS a filter in the Filter Designer's sense -- a named set
        -- of spells -- which is why they live with the bar rather than in the library.
        do
            local BuffOrderChanged = function()
                if DF.RebuildDirectFilterStrings then DF:RebuildDirectFilterStrings() end
                if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            end

            local buffOrderGroup = GUI:CreateSettingsGroup(self.child, 280)
            buffOrderGroup:AddWidget(GUI:CreateHeader(self.child, L["Order & Limits"]), GUI.RowHeight.sectionHeader)
            -- Same gate as its siblings on this page.
            buffOrderGroup.disableChildrenOn = function(d) return not d.showBuffs end

            local buffSortOptions = {
                DEFAULT = L["Default (Slot Order)"],
                TIME = L["Time Remaining"],
                NAME = L["Alphabetical"],
                APPLIED = L["Order Applied"],
                _order = { "DEFAULT", "TIME", "NAME", "APPLIED" },
            }
            buffOrderGroup:AddWidget(GUI:CreateDropdown(self.child, L["Sort Order"], buffSortOptions, db, "directBuffSortOrder", function()
                BuffOrderChanged()
                self:RefreshStates()   -- Mine First greys while Sort Order = Default
            end), 55)

            -- Sort refinements (native rows only — the legacy Lua scan doesn't read them)
            local bfSortMine = buffOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["My Auras First"], db, "directBuffSortMineFirst", BuffOrderChanged), 30)
            bfSortMine.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfSortMine.disableOn = function(d) return not DF:SortOrderSupportsMineFirst(d.directBuffSortOrder) end
            bfSortMine.tooltip = L["Sort your own auras before other players'. Unavailable on Default (which already shows yours first) and on Order Applied (which keeps one fixed order)."]
            local bfSortRev = buffOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Order"], db, "directBuffSortReverse", BuffOrderChanged), 30)
            bfSortRev.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfSortRev.tooltip = L["Reverse the sort direction."]

            -- Native-only: max TOTAL duration filter (12.1 candidateFilters.maxDuration).
            -- Hidden while the legacy render owns the row (not expressible there).
            local bfMaxDur = buffOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Long Buffs"], db, "buffMaxDurationEnabled", function()
                BuffOrderChanged()
                self:RefreshStates()
            end), 30)
            bfMaxDur.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfMaxDur.tooltip = L["Hide buffs whose total duration is longer than the threshold - e.g. hour-long food and flask buffs. Buffs with no duration (permanent auras) are also hidden while this is on."]
            local bfMaxDurSlider = buffOrderGroup:AddWidget(GUI:CreateSlider(self.child, L["Hide Longer Than (minutes)"], 1, 30, 1, db, "buffMaxDurationMinutes", nil, BuffOrderChanged), 55)
            bfMaxDurSlider.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfMaxDurSlider.disableOn = function(d) return not d.buffMaxDurationEnabled end

            -- Independent of Hide Long Buffs — but subsumed by it (a finite cap already
            -- rejects duration-0 auras), hence the tooltip honesty.
            local bfHidePerm = buffOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Permanent Auras"], db, "buffHidePermanent", BuffOrderChanged), 30)
            bfHidePerm.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfHidePerm.tooltip = L["Hide buffs with no duration, such as auras that last until cancelled. Hide Long Buffs also hides these while it is on."]
            Add(buffOrderGroup, nil, 1)
        end

        -- ===== DEDUPLICATION =====
        local dedupGroup = GUI:CreateSettingsGroup(self.child, 280)
        dedupGroup:AddWidget(GUI:CreateHeader(self.child, L["Deduplication"]), 40)
        -- The 12.1 alert banner that used to sit here is gone: both halves of the
        -- toggle are expressible again (Aura Designer via excludeSpellIDs, the
        -- Defensive Bar via its own resolved spell-ID map or a negated category —
        -- see BuildDirectBuffFilters / BuildAuraRowConfig), and the multi-filter
        -- duplicate it warned about cannot happen on a single-group buff row.
        -- What the checkbox does now fits a tooltip; a danger banner would read as
        -- "something is broken here".
        local dedupCb = GUI:CreateCheckbox(self.child, L["Hide Duplicate Buffs"], db, "buffDeduplicateDefensives", function()
            -- Bump the aura layout version so the factory buff row rebuilds with the new
            -- exclusion set (InvalidateAuraLayout -> RefreshFactoryRows -> DriveBuffFactory);
            -- UpdateAllAuras re-scans for the legacy (pre-12.1) dedup path.
            DF:InvalidateAuraLayout()
            DF:UpdateAllAuras()
        end)
        dedupCb.tooltip = L["Hides buffs that are already shown elsewhere — by an Aura Designer indicator, or on the Defensive Bar — so they don't appear twice."]
        dedupGroup:AddWidget(dedupCb, 30)
        Add(dedupGroup, nil, 1)

        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }

        -- Settings Group (col1)
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
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
        Add(settingsGroup, nil, 1)

        -- Appearance Group (col2). Icon Size / Scale / Alpha are how the row LOOKS, so
        -- they sit in column 2 with the other styling, matching Missing Buffs and
        -- Defensive Icon. They used to live in Settings above, which made this the only
        -- aura family where the same three sliders were classed as geometry.
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        local buffSize = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 10, 40, 1, db, "buffSize", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffSize.disableOn = function(d) return not d.showBuffs end
        local buffScale = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "buffScale", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffScale.disableOn = function(d) return not d.showBuffs end
        local buffAlpha = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.0, 1.0, 0.05, db, "buffAlpha", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffAlpha.disableOn = function(d) return not d.showBuffs end
        Add(appearanceGroup, nil, 2)

        -- Layout Group (col1)
        local gridGroup = GUI:CreateSettingsGroup(self.child, 280)
        gridGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout"]), 40)
        local buffWrap = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Icons Per Row"], 1, 8, 1, db, "buffWrap", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        -- Greys out (NOT a 12.1 frost) whenever the row can't have more than one icon per
        -- line: the row is off, or the growth is vertical-primary, where the native flow
        -- renders a single column and "icons per row" has nothing to count. That's ordinary
        -- contextual state — the control works fine horizontally — so it uses the normal grey
        -- seam rather than the 12.1 blocked registry, which is reserved for "the game cannot
        -- do this". Flipping Orientation re-enables it live via RefreshStates.
        -- (Why a vertical column is unavoidable, re-verified against the 68914 dump:
        --  ValidateAuraGroupLayoutOptions accepts only elementSpacing / lineSpacing /
        --  groupSpacing / groupLineSpacing / forceNewLine / elementWidth / elementHeight /
        --  layoutIndex — no primary-axis field and no wrap count — and
        --  SetFlowLayoutGrowthDirection(h, v) picks which way lines grow, not whether the
        --  flow is column-primary.)
        buffWrap.disableOn = function(d)
            if not d.showBuffs then return true end
            local g = d.buffGrowth or ""
            -- Vertical-primary AND vertical-centred growth both render a single column.
            return DF:FactoryOwnsBuffRow(d) and (g:sub(1, 2) == "UP" or g:sub(1, 4) == "DOWN"
                or g == "CENTER_LEFT" or g == "CENTER_RIGHT")
        end
        -- CENTER growth direction: supported on factory rows since the centre-pinned
        -- box in AuraContainer.lua resolveGrowthLayout (the self-sizing container
        -- keeps the row centred) — the old blocked-registry entry is gone.
        local buffPaddingX = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing X"], -5, 10, 1, db, "buffPaddingX", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffPaddingX.disableOn = function(d) return not d.showBuffs end
        local buffPaddingY = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing Y"], -5, 10, 1, db, "buffPaddingY", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffPaddingY.disableOn = function(d) return not d.showBuffs end
        Add(gridGroup, nil, 1)

        -- Position Group (col1)
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        local buffAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "buffAnchor", nil), 55)
        buffAnchor.disableOn = function(d) return not d.showBuffs end
        local buffGrowth = positionGroup:AddWidget(GUI:CreateGrowthControl(self.child, db, "buffGrowth", nil), 155)
        buffGrowth.disableOn = function(d) return not d.showBuffs end
        local buffOffsetX = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "buffOffsetX", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffOffsetX.disableOn = function(d) return not d.showBuffs end
        local buffOffsetY = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "buffOffsetY", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffOffsetY.disableOn = function(d) return not d.showBuffs end
        Add(positionGroup, nil, 1)

        -- Border Group (col2)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        -- Full border toolkit via the unified helper (Stage 5.5 Phase 2).  No
        -- class/role colour (aura indicators aren't unit-class).  Greys out when
        -- buffs are off, like every other control on this page.
        -- Border Animation is intentionally NOT offered on the buff/debuff rows:
        -- these containers can hold many icons and animating each border is a
        -- per-frame FPS cost, so DF exposes border animations only on the
        -- low-count elements (Defensive / Missing Buff) and the Aura Designer.
        GUI:CreateBorderControls(borderGroup, db, "buff", {
            parent        = self.child,
            include       = { inset = true, offset = true, blendMode = true,
                              gradient = true, shadow = true, alpha = true },
            sizeMin = 0, sizeMax = 8, sizeStep = 1,
            fullUpdate    = function() if DF.UpdateAllFrames then DF:UpdateAllFrames() end end,
            lightUpdate   = function() DF:LightweightUpdateAuraBorder("buff") end,
            lightColors   = function() DF:LightweightUpdateAuraBorder("buff") end,
            refreshStates = function() self:RefreshStates() end,
            disableWhen   = function(d) return not d.showBuffs end,
        })
        -- ☠ COLUMN 1, deliberately against the usual "styling goes right" split. This page
        -- is almost entirely styling — Appearance, Border, Stack Count, Duration, Duration
        -- Bar, Pandemic — so applying the split literally piles six boxes on the right and
        -- leaves the left half empty: measured at 885 vs 2639. Two styling boxes have to
        -- cross, and the two that do are the ones applied to the WHOLE icon rather than
        -- drawn on it: Border (most tied to geometry — size, inset, offsets — and reads
        -- naturally after Position) and Pandemic below it. That brings the columns to
        -- 1781 vs 1743. The doctrine's own "when possible" is doing the work here; a page
        -- that is 3x out of balance is a worse failure than a box on the wrong side.
        Add(borderGroup, nil, 1)

        -- Duration Text Group (col2)
        -- "Duration Text", not "Duration": this box and Duration Bar are two renderings of
        -- the same value, and a bare "Duration" made the pair look like one had been
        -- separated from the other. The name says which one this is — and matches what the
        -- Aura Designer cards have always called it.
        local durationGroup = GUI:CreateSettingsGroup(self.child, 280)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Text"]), 40)
        durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Duration"], db, "buffShowDuration", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        -- The cooldown swipe (radial sweep) is the OTHER way time-remaining is
        -- shown, so it lives here with Duration Text rather than under Border.
        durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Cooldown Swipe"], db, "buffHideSwipe", nil), 30)
        -- Icon-sized formats only: Number "14" / Seconds "14s" / Percent "45%".
        -- FULL ("14 Seconds") overflows a 20px icon (never fit, delisted with #5's
        -- percent work — a saved FULL still renders until the user re-picks); the
        -- combined "12s (45%)" is AD-bar-only for the same reason.
        -- The icon rows carry the three time formats plus Percent; FULL and the percent
        -- composite stay on the Aura Designer bar, which has the width for them.
        local durationFormatOptions = { NUMBER = L["Standard"], SHORT = L["Units"],
            TIMER = L["Timer"], PERCENT = L["Percent"],
            _order = { "NUMBER", "SHORT", "TIMER", "PERCENT" } }
        local durFormat = GUI:CreateDurationFormatControls(self.child, durationGroup, durationFormatOptions, db, "buffDurationFormat", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames(); GUI:RefreshCurrentPage() end)
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
        AddColorsPageLink(durationGroup, self.child)
        -- Hide Above can't compose with the Percent format (its threshold is seconds
        -- banded into a seconds-sampled formatter — see GetDurationFormatFields).
        local durHideAbove = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Above Threshold"], db, "buffDurationHideAboveEnabled", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
        durHideAbove.disableOn = function(d) return not d.buffShowDuration or DF:IsPercentDurationFormat(d.buffDurationFormat) end
        local durHideAboveSlider = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Hide Above (seconds)"], 1, 60, 1, db, "buffDurationHideAboveThreshold", nil, function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
        durHideAboveSlider.disableOn = function(d) return not d.buffShowDuration or not d.buffDurationHideAboveEnabled or DF:IsPercentDurationFormat(d.buffDurationFormat) end
        local durHidePerm = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Duration on Permanent Auras"], db, "buffDurationHideOnPermanent", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
        durHidePerm.disableOn = function(d) return not d.buffShowDuration end
        -- Grey the whole group when Buffs are off (composes with the per-control
        -- buffShowDuration gates), matching Settings/Position/Grid.
        durationGroup.disableChildrenOn = function(d) return not d.showBuffs end
        Add(durationGroup, nil, 2)

        -- Stack Count Group (col2) — the shared TextStyle control block (font/scale/
        -- outline/shadow/colour/anchor/offsets/justify) + the feature-specific extras.
        -- Directly under Duration, and in that order on every surface that has both: they
        -- are the two text elements on an icon and are tuned as a pair, so a user looking
        -- for one expects the other adjacent. Matches the Aura Designer cards.
        local stackCountGroup = GUI:CreateSettingsGroup(self.child, 280)
        stackCountGroup:AddWidget(GUI:CreateHeader(self.child, L["Stack Count"]), 40)
        GUI:CreateTextControls(stackCountGroup, db, "buffStack", {
            parent   = self.child,
            include  = { color = true },
            onChange = function() DF:LightweightUpdateAuraStackText("buff") end,
            onDrag   = function() DF:LightweightUpdateAuraStackText("buff") end,
        })
        -- (No "Min Stacks to Show": a stacks formatter is FORBIDDEN on container rows — it
        -- throws on the secret combat stack count inside Blizzard's dirty pass and bricks
        -- the container (see the Features/Auras.lua tombstone). Native display is
        -- "counts > 1", so a custom minimum cannot be expressed; the setting is gone.)
        -- Grey the whole group when Buffs are off, matching Settings/Position/Grid.
        stackCountGroup.disableChildrenOn = function(d) return not d.showBuffs end
        Add(stackCountGroup, nil, 2)

        -- (No Expiring Indicator group: the pre-12.1 expiring border/tint was driven by a
        -- ~3 Hz ticker reading remaining time, which is SECRET on 12.1. Removed 2026-07-25
        -- rather than left frosted. The 12.1-safe replacement is the DF.Expiration engine
        -- (Features/Expiration.lua) + GUI:CreateExpirationControls, currently adopted by the
        -- Aura Designer only -- rolling it out to these rows is a separate, unscheduled job.)

        -- ===== DURATION BAR ===== (12.1 factory rows only — the native
        -- container drains the strip render-side; the legacy renderer has no bar)
        --
        -- The collapsible section used to carry this predicate and hide the bar
        -- with itself; with the section gone the box declares it directly.
        local function HideDurationBar(d) return not DF:FactoryOwnsBuffRow(d) end

        -- Every bar edit routes through the factory drive: the sig split decides
        -- Rebuild (enable/position/height/gap — layout reservation) vs in-place
        -- restyle (texture/colours) — same callback either way.
        local function BuffBarChanged() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end

        local durBarGroup = GUI:CreateSettingsGroup(self.child, 280)
        durBarGroup.hideOn = HideDurationBar
        -- "Duration Bar", not "Settings": the section that scoped that name is
        -- gone, and the page already has a Settings box at the top.
        durBarGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Bar"]), 40)
        durBarGroup:AddWidget(GUI:CreateLabel(self.child, L["Shows a bar on each icon that drains with the aura's remaining time."], 250), 30)
        local buffBarEnable = durBarGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Duration Bar"], db, "buffDurationBarEnabled", function()
            self:RefreshStates()
            BuffBarChanged()
        end), 30)
        buffBarEnable.keepEnabled = true
        buffBarEnable.disableOn = function(d) return not d.showBuffs end
        durBarGroup.disableChildrenOn = function(d) return not d.showBuffs or not d.buffDurationBarEnabled end
        -- Where the bar sits, then what it looks like. One box rather than two,
        -- matching Debuffs: every other optional element on the page is a single
        -- box, and splitting only this one made the bar read as more of a feature
        -- than its neighbours while taking up half of column 2.
        durBarGroup:AddWidget(GUI:CreateDropdown(self.child, L["Position"], { BOTTOM = L["Bottom"], TOP = L["Top"] }, db, "buffDurationBarPosition", BuffBarChanged), 55)
        durBarGroup:AddWidget(GUI:CreateSlider(self.child, L["Height"], 1, 12, 1, db, "buffDurationBarHeight", nil, BuffBarChanged, true), 55)
        durBarGroup:AddWidget(GUI:CreateSlider(self.child, L["Gap"], 0, 10, 1, db, "buffDurationBarGap", nil, BuffBarChanged, true), 55)
        durBarGroup:AddWidget(GUI:CreateDropdown(self.child, L["Color Mode"], DF:GetDurationBarColorModes(), db, "buffDurationBarColorMode", function()
            self:RefreshStates()
            BuffBarChanged()
        end), 55)
        local buffBarTex = durBarGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "buffDurationBarTexture", BuffBarChanged), 55)
        local buffBarCol = durBarGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Bar Color"], db, "buffDurationBarColor", true, BuffBarChanged), 30)
        -- A curve mode brings its own ramp texture and forces white, so these two do
        -- nothing while it is selected - dim them rather than leave dead controls live.
        buffBarTex.disableOn = function(d) return DF:IsDurationBarCurveMode(d.buffDurationBarColorMode) end
        buffBarCol.disableOn = buffBarTex.disableOn
        durBarGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "buffDurationBarBGColor", true, BuffBarChanged), 30)
        durBarGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Fill"], db, "buffDurationBarReverseFill", BuffBarChanged), 30)
        Add(durBarGroup, nil, 2)

        -- ===== PANDEMIC ===== (12.1 factory rows only, and only on PTR 8+ clients —
        -- CreatePandemicControls greys itself and says why on an older build.)
        --
        -- This is the ROW half of the feature the Aura Designer cards also carry. There is
        -- deliberately NO Expiration section on this page (the pre-12.1 expiring border was
        -- removed above and its 12.1 replacement is AD-only so far), so no collision check is
        -- passed — nothing here can clash with anything.
        local pandemicGroup = GUI:CreateSettingsGroup(self.child, 280)
        pandemicGroup.hideOn = HideDurationBar   -- same gate: no factory row, no button to hang it on
        pandemicGroup:AddWidget(GUI:CreateHeader(self.child, L["Pandemic"]), 40)
        pandemicGroup:AddWidget(GUI:CreateLabel(self.child, L["Highlights each icon once the aura can be refreshed without losing time."], 250), 30)
        GUI:CreatePandemicControls(pandemicGroup, db, {
            parent     = self.child,
            prefix     = "buff",
            -- The row has to exist before any of this means anything; the helper folds this
            -- into both its group gate and its Enable toggle.
            masterGate = function(d) return not d.showBuffs end,
            fullUpdate = function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end,
            refreshStates = function() self:RefreshStates() end,
        })
        -- ☠ COLUMN 1, and it lands under Border rather than at the source position you would
        -- guess from reading down this file. Column 1 is layout PLUS the treatments applied
        -- to the whole icon (Border, then Pandemic, which is a border or a tint); column 2
        -- is the elements drawn ON the icon (Appearance, Duration, Stack Count, Duration
        -- Bar). That split is what lets Duration and Stack Count sit together on the right
        -- without tipping the page over -- Pandemic crossing left is the near-exact
        -- counterweight for Stack Count crossing right (442 vs 408). Debuffs runs the same
        -- seven-group column 1 with Important Debuffs in this slot.
        -- ⚠ Crossed BACK to column 2. Read the note above for why it was ever in
        -- column 1: applying the structure/styling split literally gave 885 vs 2639,
        -- so Border and Pandemic were deliberately moved left to reach 1781 vs 1743.
        --
        -- Column 1 has since gained the Buff Filters box -- which is TALLER THAN ANY
        -- OTHER GROUP ON THE PAGE and, uniquely, a variable height, because it lists
        -- one row per built-in filter plus one per custom filter the user has made.
        -- That inverted the imbalance the crossing was correcting.
        --
        -- Pandemic goes back and Border stays: of the two, Border is the one the note
        -- calls "most tied to geometry — size, inset, offsets — and reads naturally
        -- after Position", while Pandemic is drawn on the icon. Border has the better
        -- claim to column 1 on merit, so it keeps the seat.
        --
        -- ☠ The old counterweight arithmetic can no longer be recomputed here. With a
        -- variable-height group in column 1 there is no static answer; balance has to
        -- be judged on screen, with a realistic number of custom filters.
        Add(pandemicGroup, nil, 2)

        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_filterdesigner", label = L["Filter Designer"]},
            {pageId = "display_tooltips", label = L["Buff Tooltips"]},
            {pageId = "general_integrations", label = L["Integrations"]},
            {pageId = "auras_missingbuffs", label = L["Missing Buffs"]},
        }), 30, "both")
    end)

    -- Auras > Debuffs (combined Layout + Appearance with collapsible sections)
    -- "Debuff Bar" for the same reason as the Buff Bar page: this owns appearance
    -- and placement, Aura Filters owns which debuffs appear at all.
    local pageDebuffs = CreateSubTab("auras", "auras_debuffs", L["Debuff Bar"])
    BuildPage(pageDebuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- ☠ NO source banner here either, and this one was worse than redundant: it
        -- said the categories were set in Aura Filters, which stopped being true the
        -- moment they moved onto this page. Both halves are now in the Debuff Filters
        -- group below.

        -- Copy button at top
        -- "directDebuff" — same omission as Buffs above, plus ShowAll / DispellableMode.
        -- ⚠ debuffBlacklist joined this list with the Optional Debuffs group. The
        -- "debuff" prefix already covers debuffFilterBoss/Role/... and
        -- "directDebuff" covers ShowAll / DispellableMode, but debuffBlacklist is
        -- matched by "debuff" only by luck of spelling — it is named outright so the
        -- ownership is stated rather than inferred.
        Add(CreateCopyButton(self.child, {"debuff", "showDebuffs", "directDebuff", "debuffBlacklist"}, L["Debuff Bar"], "auras_debuffs"), 25, 2)

        -- Shared by both groups below: rebuild the native filter strings and re-drive
        -- the container rows. The blacklist rides the same refresh because the debuff
        -- row's excludeSpellIDs merge reacts to exactly this pair
        -- (Features/Auras.lua applyDebuffBlacklist).
        local function DebuffFilterChanged()
            if DF.RebuildDirectFilterStrings then DF:RebuildDirectFilterStrings() end
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
        end

        -- ===== DEBUFF FILTERS (Column 1, first) =====
        -- WHICH debuffs reach this bar, moved here from the Aura Filters page.
        --
        -- ☠ These are NOT filters in the registry sense and there is no Manage
        -- Filters button, because there is nothing to manage: membership is
        -- Blizzard's and cannot be edited, added to or duplicated. That difference
        -- is the single most misleading thing about the old shared page, where these
        -- switches sat under the same tab strip as the editable buff library and
        -- looked identical to it. Here they are simply this bar's own controls.
        do
            local filterGroup = GUI:CreateSettingsGroup(self.child, 280)
            filterGroup:AddWidget(GUI:CreateHeader(self.child, L["Debuff Filters"]), 40)
            filterGroup:AddWidget(GUI:CreateLabel(self.child,
                "|cff888888" .. L["These categories are Blizzard's and cannot be edited."] .. "|r", 250), 35)

            local showAllCb = filterGroup:AddWidget(GUI:CreateCheckbox(self.child, L["All Debuffs"], db, "directDebuffShowAll", function()
                self:RefreshStates()
                DebuffFilterChanged()
            end), 30)
            showAllCb.tooltip = L["All Debuffs"]
            showAllCb.tooltipDesc = L["Show every debuff with no filtering."]

            -- The only real warning here, and it is about the COMBINATION: any single
            -- category obviously misses things, so saying that adds nothing. What is
            -- surprising is that switching on every category still is not All
            -- Debuffs, because Blizzard tagged some debuffs with none of them.
            filterGroup:AddWidget(GUI:CreateLabel(self.child,
                "|cff888888" .. L["Only All Debuffs shows every debuff: all the categories combined still miss some debuffs."] .. "|r", 250), 45)

            -- Blizzard's fixed categories, in the order the old page listed them.
            local DEBUFF_CATEGORIES = {
                { key = "debuffFilterBoss",         name = "Boss Debuffs",        desc = "Debuffs applied by dungeon and raid bosses." },
                { key = "debuffFilterRole",         name = "Role Debuffs",        desc = "Debuffs Blizzard flags as important for your role." },
                { key = "debuffFilterPriority",     name = "Priority Debuffs",    desc = "Debuffs Blizzard flags as high priority." },
                { key = "debuffFilterCrowdControl", name = "Crowd Control",       desc = "CC effects like stuns, roots, and incapacitates." },
                { key = "debuffFilterRaid",         name = "Raid Debuffs",        desc = "Other debuffs Blizzard flags for raid frames." },
                -- ⚠ "just below" stays true on this page: the dispel-mode dropdown
                -- is the next widget in this same group.
                { key = "debuffFilterDispellable",  name = "Dispellable Debuffs", desc = "Debuffs that can be dispelled. Which dispels count is set just below." },
            }
            for _, cat in ipairs(DEBUFF_CATEGORIES) do
                local cb = filterGroup:AddWidget(GUI:CreateCheckbox(self.child, L[cat.name], db, cat.key, function()
                    self:RefreshStates()
                    DebuffFilterChanged()
                end), 30)
                cb.tooltip = L[cat.name]
                cb.tooltipDesc = L[cat.desc]
                -- All Debuffs overrides the whole list.
                cb.disableOn = function(d) return d.directDebuffShowAll end
            end

            -- Which dispels count: a sub-option of the Dispellable Debuffs row above.
            -- ⚠ BOTH its gates live in this group now, so unlike its previous home it
            -- can never be greyed with nothing on the page able to lift it.
            local dispelDD = filterGroup:AddWidget(GUI:CreateDropdown(self.child, L["Dispellable Debuffs"], {
                PLAYER = L["Dispellable By Me"],
                ALL    = L["All Dispellable"],
                ANY    = L["Any Dispel Type"],
                _order = { "PLAYER", "ALL", "ANY" },
            }, db, "directDebuffDispellableMode", function()
                DebuffFilterChanged()
            end), 55)
            dispelDD.disableOn = function(d)
                return d.directDebuffShowAll or not d.debuffFilterDispellable
            end
            dispelDD.tooltip = L["Dispellable By Me: only debuffs you can dispel. All Dispellable: any debuff that can be dispelled. Any Dispel Type: every debuff with a dispel type, even ones that cannot be dispelled."]

            Add(filterGroup, nil, 1)
        end

        -- ===== DEBUFF BLACKLIST (Column 2) =====
        -- The one debuff thing on this page that IS yours: a short fixed catalog of
        -- nuisance debuffs the game leaves non-secret, so they can be hidden
        -- (Sated/Exhaustion, the Deserters, Ride Along, Challenger's Burden).
        --
        -- ☠ SELECT TO HIDE — the checkbox is a BLACKLIST entry, not a visibility
        -- switch, and it is the one control in the addon whose tick does not mean
        -- "show this". It reads directly: the box is the blacklist, ticking it puts
        -- the debuff on the blacklist, and the stored set is exactly what is ticked.
        --
        -- It used to be inverted -- presented as "Optional Debuffs", box = shown,
        -- unselect to hide -- which kept the addon's usual polarity at the cost of
        -- the getter and setter both negating, and of a list called a blacklist
        -- whose ticks meant the opposite. Krathe's call, 2026-08-10: name it what it
        -- is and let the tick match the name. Storage is unchanged; only the
        -- presentation flipped, so existing profiles keep hiding what they hid.
        do
            local catalog = (DF.AuraBlacklist and DF.AuraBlacklist.DebuffSpells) or {}
            if #catalog > 0 then
                local blGroup = GUI:CreateSettingsGroup(self.child, 280)
                blGroup:AddWidget(GUI:CreateHeader(self.child, L["Debuff Blacklist"]), 40)
                blGroup:AddWidget(GUI:CreateLabel(self.child,
                    "|cff888888" .. L["Select a debuff to hide it from this bar. These are the only debuffs the game lets us hide."] .. "|r", 250), 45)

                local function BlacklistSet()
                    db.debuffBlacklist = db.debuffBlacklist or {}
                    return db.debuffBlacklist
                end

                for _, e in ipairs(catalog) do
                    local id = e.spellId
                    -- Resolve the live client name so the row localises like the rest
                    -- of the UI; the catalog's English display is the fallback.
                    local name = e.display
                    if C_Spell and C_Spell.GetSpellName then
                        local ok, v = pcall(C_Spell.GetSpellName, id)
                        if ok and type(v) == "string" and v ~= "" then name = v end
                    end
                    -- Direct binding, no negation on either side: ticked == blacklisted.
                    blGroup:AddWidget(GUI:CreateCheckbox(self.child, name, nil, nil, DebuffFilterChanged,
                        function() return BlacklistSet()[id] and true or false end,
                        function(v)
                            local s = BlacklistSet()
                            s[id] = v or nil
                        end), 30)
                end

                -- Restore the shipped set. Mutated IN PLACE for the same reason the
                -- selection tables are: the aura pipeline holds a reference to this
                -- table and a fresh one would strand it.
                local resetBtn = blGroup:AddWidget(GUI:CreateButton(self.child, L["Reset"], 140, 22, function()
                    local defaults = (db == DF.db.raid) and DF.RaidDefaults or DF.PartyDefaults
                    local def = defaults and defaults.debuffBlacklist
                    local s = BlacklistSet()
                    for id in pairs(s) do s[id] = nil end
                    if type(def) == "table" then
                        for id, on in pairs(def) do s[id] = on or nil end
                    end
                    self:RefreshStates()
                    DebuffFilterChanged()
                end), 30)
                resetBtn.tooltip = L["Debuff Blacklist"]

                -- ⚠ Column 1, with the filters, not column 2. It is a CONTENT
                -- decision -- which debuffs reach the bar -- and column 2 on this
                -- page is styling. It also helps the balance, since column 2 carries
                -- Duration Text, Stack Count, Dispel Text and Duration Bar; but the
                -- reason is that it belongs beside the categories it narrows.
                Add(blGroup, nil, 1)
            end
        end

        -- ===== ORDER & LIMITS (Column 1, under the filters) =====
        -- ⚠ MOVED UP FROM THE FOOT OF THE PAGE. Within a column the Add() order IS
        -- the layout order, so this block had to move bodily -- there is no insert-at.
        --
        -- It sits under the two filter boxes because it is the rest of the same
        -- question: those decide WHICH debuffs qualify, this decides how many of them
        -- you get and in what order. Eight boxes below, under Position and Border, it
        -- read as a styling option.
        --
        -- Neither of these IS a filter in the Filter Designer's sense, which is why
        -- they live with the bar rather than in the library.
        local debuffOrderGroup = GUI:CreateSettingsGroup(self.child, 280)
        debuffOrderGroup:AddWidget(GUI:CreateHeader(self.child, L["Order & Limits"]), GUI.RowHeight.sectionHeader)
        -- ⚠ The four sibling boxes on this page (Duration Text, Stack Count, Dispel Symbol,
        -- Duration Bar) all gate on showDebuffs; this one was simply missed, so it stayed
        -- live while the row it orders was switched off (Krathe, 2026-08-09).
        debuffOrderGroup.disableChildrenOn = function(d) return not d.showDebuffs end

        local debuffSortOptions = {
            DEFAULT = L["Default (Slot Order)"],
            TIME = L["Time Remaining"],
            NAME = L["Alphabetical"],
            APPLIED = L["Order Applied"],
            _order = { "DEFAULT", "TIME", "NAME", "APPLIED" },
        }
        debuffOrderGroup:AddWidget(GUI:CreateDropdown(self.child, L["Sort Order"], debuffSortOptions, db, "directDebuffSortOrder", function()
            DebuffFilterChanged()
            self:RefreshStates()
        end), 55)

        local dfSortMine = debuffOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["My Auras First"], db, "directDebuffSortMineFirst", DebuffFilterChanged), 30)
        dfSortMine.hideOn = function(d) return not DF:FactoryOwnsDebuffRow(d) end
        dfSortMine.disableOn = function(d) return not DF:SortOrderSupportsMineFirst(d.directDebuffSortOrder) end
        dfSortMine.tooltip = L["Sort your own auras before other players'. Unavailable on Default (which already shows yours first) and on Order Applied (which keeps one fixed order)."]
        local dfSortRev = debuffOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Order"], db, "directDebuffSortReverse", DebuffFilterChanged), 30)
        dfSortRev.hideOn = function(d) return not DF:FactoryOwnsDebuffRow(d) end
        dfSortRev.tooltip = L["Reverse the sort direction."]

        -- ☠ "Dispellable Debuffs" (directDebuffDispellableMode) MOVED to Auras > Aura
        -- Filters > Debuffs, under the category row it belongs to. It lived here gated on
        -- `directDebuffShowAll or not debuffFilterDispellable` — and BOTH of those are set
        -- on the Filters page, so with All Debuffs on by default it was permanently greyed
        -- and nothing on this page could lift it (Krathe, 2026-08-09).
        -- ⚠ Do not re-add it here. The storage is unchanged (same per-mode key); only the
        -- control moved, and its sync/reset ownership moved with it — see
        -- DF.SECTION_PREFIXES, where auras_filterdesigner now claims the key.

        -- Works in ALL-debuffs mode too (single maxDuration record) — only Keep
        -- Important needs the category filters (boolean flags can't be negated on
        -- the ALL record), so THAT toggle alone greys while All Debuffs is on.
        local function HideDebuffMaxDurControls(d)
            return not DF:FactoryOwnsDebuffRow(d)
        end
        local dfMaxDur = debuffOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Long Debuffs"], db, "debuffMaxDurationEnabled", function()
            DebuffFilterChanged()
            self:RefreshStates()
        end), 30)
        dfMaxDur.hideOn = HideDebuffMaxDurControls
        dfMaxDur.tooltip = L["Hide debuffs whose total duration is longer than the threshold. Debuffs with no duration (permanent auras) are also hidden while this is on."]
        local dfMaxDurSlider = debuffOrderGroup:AddWidget(GUI:CreateSlider(self.child, L["Hide Longer Than (minutes)"], 1, 30, 1, db, "debuffMaxDurationMinutes", nil, DebuffFilterChanged), 55)
        dfMaxDurSlider.hideOn = HideDebuffMaxDurControls
        dfMaxDurSlider.disableOn = function(d) return not d.debuffMaxDurationEnabled end

        local dfKeepImportant = debuffOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Keep important debuffs"], db, "debuffMaxDurationKeepImportant", DebuffFilterChanged), 30)
        dfKeepImportant.hideOn = HideDebuffMaxDurControls
        dfKeepImportant.disableOn = function(d)
            return d.directDebuffShowAll or not d.debuffMaxDurationEnabled
        end
        dfKeepImportant.tooltip = L["Boss, Role, and Priority debuffs stay visible even when their duration is over the threshold."]
        Add(debuffOrderGroup, nil, 1)

        
        
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }

        -- ===== DEDUPLICATION =====
        -- Same section, same position as the Buffs page: its own box at the top
        -- of column 1, ahead of Settings. The two pages' dedupe toggles must be
        -- findable in the same place.
        local dedupGroup = GUI:CreateSettingsGroup(self.child, 280)
        dedupGroup:AddWidget(GUI:CreateHeader(self.child, L["Deduplication"]), 40)
        -- This was inlined because the only refresh helper used to be declared with
        -- the Order & Limits box FURTHER DOWN the function, so naming it here would
        -- have been a nil global — legal Lua, parses clean, silently dead checkbox.
        -- DebuffFilterChanged is page-scope now, above every group that needs it, so
        -- the hazard is gone and this simply calls it.
        local dfDedup = GUI:CreateCheckbox(self.child, L["Hide Duplicate Debuffs"], db, "debuffDeduplicateDesigner", DebuffFilterChanged)
        dfDedup.tooltip = L["Hides debuffs that an Aura Designer group is already showing, so they don't appear twice."]
        dedupGroup:AddWidget(dfDedup, 30)
        Add(dedupGroup, nil, 1)

        -- Settings Group (col1)
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Debuffs"], db, "showDebuffs", function()
            self:RefreshStates()
            -- See Show Buffs above: re-scan auras on visible frames so a static
            -- debuff hides/shows immediately instead of waiting for the next aura event.
            DF:RefreshAllVisibleFrames()
        end), 30)
        local debuffMax = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Debuffs"], 0, 8, 1, db, "debuffMax", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        debuffMax.disableOn = function(d) return not d.showDebuffs end
        Add(settingsGroup, nil, 1)

        -- Appearance Group (col2) -- mirrors Buffs; see the note there.
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        local debuffSize = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 10, 40, 1, db, "debuffSize", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffSize.disableOn = function(d) return not d.showDebuffs end
        local debuffScale = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "debuffScale", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffScale.disableOn = function(d) return not d.showDebuffs end
        local debuffAlpha = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.0, 1.0, 0.05, db, "debuffAlpha", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffAlpha.disableOn = function(d) return not d.showDebuffs end
        Add(appearanceGroup, nil, 2)

        -- ===== IMPORTANT DEBUFFS (col2) =====
        -- Boss/role and priority debuffs already render as their OWN aura groups, and
        -- those groups are declared first — so they already lead the row. Everything
        -- here styles them so they also LOOK different without moving to a separate
        -- placement. Every change is STRUCTURAL (region presence / group layout cell /
        -- the group's init closure), so each callback must invalidate rather than
        -- lightweight-reposition — same pair the Hide Duplicate Debuffs toggle uses.
        local function ImportantChanged()
            if DF.RebuildDirectFilterStrings then DF:RebuildDirectFilterStrings() end
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
        end
        local function ImportantOff(d) return not d.showDebuffs or not d.debuffImportantHighlight end

        local impGroup = GUI:CreateSettingsGroup(self.child, 280)
        impGroup:AddWidget(GUI:CreateHeader(self.child, L["Important Debuffs"]), 40)
        impGroup:AddWidget(GUI:CreateLabel(self.child,
            L["Makes boss, role and priority debuffs stand out in the normal debuff row."], 250), 30)
        local impOn = impGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Highlight Important Debuffs"],
            db, "debuffImportantHighlight", ImportantChanged), 30)
        impOn.disableOn = function(d) return not d.showDebuffs end
        impOn.tooltip = L["Boss, role and priority debuffs already sort to the front of the row. This also makes them larger and marks them, so they read at a glance without needing their own placement."]

        -- CreateSlider(parent, label, min, max, step, db, key, callback, lightweightUpdate,
        -- usePreviewMode, ...) — arg 8 is the release callback, arg 9 the per-drag-tick one
        -- and arg 10 the boolean that arms it.
        --
        -- ☠ NO LIGHTWEIGHT PATH ON ANY OF THE FOUR SLIDERS IN THIS SECTION, and it must
        -- stay that way. Every key here feeds recStyleSig (Features/Auras.lua), which is
        -- part of the STRUCTURAL signature — so each new value forces h:Rebuild: a
        -- NativeBackend:teardown plus a fresh container and fresh buttons, per rendered
        -- frame per visible unit. applyRecordStyle then creates a badge host frame and two
        -- textures per styled button, and WoW never frees a frame. Wired to the drag tick,
        -- a few seconds of dragging in a 20-man leaked frames by the thousand. The
        -- "documented frame-leak case" note in AuraContainer.lua is about this path.
        --
        -- The cost is that the preview moves on release rather than under the cursor. That
        -- is the deliberate trade: one rebuild per adjustment is the price every other
        -- structural setting pays, and it is bounded.
        --
        -- ⚠ The better fix is to let badge geometry ride ApplyStyle instead of forcing a
        -- rebuild — applyRecordStyle is already idempotent and safe to re-run — but the
        -- record style is captured as an upvalue in the secure initializeFrame closure, so
        -- a live read has to be plumbed through first. That is engine work, not a slider
        -- change, and narrowing the signature WITHOUT it would leave these sliders writing
        -- to the DB while nothing on screen moves.
        local impScale = impGroup:AddWidget(GUI:CreateSlider(self.child, L["Size Step"], 1.0, 2.0, 0.05,
            db, "debuffImportantScale", ImportantChanged), 55)
        impScale.disableOn = ImportantOff
        impScale.tooltip = L["How much larger an important debuff renders. 1.00 keeps it the same size as the rest of the row."]

        local impBadge = impGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Corner Marker"],
            db, "debuffImportantBadge", ImportantChanged), 30)
        impBadge.disableOn = ImportantOff
        impBadge.tooltip = L["A small marker on the corner of the icon. It survives being shrunk better than a colour change, and it does not compete with the dispel border."]

        local impBadgeSize = impGroup:AddWidget(GUI:CreateSlider(self.child, L["Marker Size"], 6, 20, 1,
            db, "debuffImportantBadgeSize", ImportantChanged), 55)
        impBadgeSize.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

        -- hasAlpha=false, and NO lightweight path: a colour change here rebuilds the
        -- group (the tint is baked at initializeFrame), so there is nothing cheaper to
        -- run on drag. Signature is (parent, label, db, key, hasAlpha, cb, lightCb, useLight).
        -- Corner + nudge. Offsets are ADDED to a built-in overhang that pushes the badge
        -- out of whichever corner is picked, so 0/0 is already a sensible resting place.
        local badgePoints = { TOPRIGHT = L["Top Right"], TOPLEFT = L["Top Left"],
                              BOTTOMRIGHT = L["Bottom Right"], BOTTOMLEFT = L["Bottom Left"] }
        local impBadgePt = impGroup:AddWidget(GUI:CreateDropdown(self.child, L["Marker Corner"],
            badgePoints, db, "debuffImportantBadgePoint", ImportantChanged), 55)
        impBadgePt.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

        local impBadgeX = impGroup:AddWidget(GUI:CreateSlider(self.child, L["Marker Offset X"], -20, 20, 1,
            db, "debuffImportantBadgeX", ImportantChanged), 55)
        impBadgeX.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

        local impBadgeY = impGroup:AddWidget(GUI:CreateSlider(self.child, L["Marker Offset Y"], -20, 20, 1,
            db, "debuffImportantBadgeY", ImportantChanged), 55)
        impBadgeY.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

        local impBadgeCol = impGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Marker Color"],
            db, "debuffImportantBadgeColor", false, ImportantChanged, nil, false), 35)
        impBadgeCol.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

        local impMarkCol = impGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Marker Symbol Color"],
            db, "debuffImportantMarkColor", false, ImportantChanged, nil, false), 35)
        impMarkCol.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end
        -- ☠ NO Add() HERE — this box is placed further down, immediately after Border, so it
        -- lands in column 1 UNDER Border rather than third from the top. Placement follows
        -- Add() call order within a column, and the group has to be built before it can be
        -- placed; the block stays here (it is long, and moving it buys nothing) while the
        -- Add sits at the position it actually occupies. See the note at that Add.

        -- Layout Group (col1)
        local gridGroup = GUI:CreateSettingsGroup(self.child, 280)
        gridGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout"]), 40)
        local debuffWrap = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Icons Per Row"], 1, 8, 1, db, "debuffWrap", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffWrap.disableOn = function(d) return not d.showDebuffs end
        local debuffPaddingX = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing X"], -5, 10, 1, db, "debuffPaddingX", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffPaddingX.disableOn = function(d) return not d.showDebuffs end
        local debuffPaddingY = gridGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing Y"], -5, 10, 1, db, "debuffPaddingY", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffPaddingY.disableOn = function(d) return not d.showDebuffs end
        Add(gridGroup, nil, 1)
        -- Position Group (col2)
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
        local debuffAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "debuffAnchor", nil), 55)
        debuffAnchor.disableOn = function(d) return not d.showDebuffs end
        local debuffGrowth = positionGroup:AddWidget(GUI:CreateGrowthControl(self.child, db, "debuffGrowth", nil), 155)
        debuffGrowth.disableOn = function(d) return not d.showDebuffs end
        local debuffOffsetX = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "debuffOffsetX", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffOffsetX.disableOn = function(d) return not d.showDebuffs end
        local debuffOffsetY = positionGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "debuffOffsetY", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffOffsetY.disableOn = function(d) return not d.showDebuffs end
        Add(positionGroup, nil, 1)

        local function InvalidateAndUpdate()
            DF.debuffBorderCurve = nil
            DF:UpdateAllFrames()
        end
        
        -- Border Group (col1)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        -- Full border toolkit via the unified helper (Stage 5.5 Phase 2).  When
        -- "Color by Dispel Type" (below) is ON, the border is forced SOLID and
        -- recoloured per dispel type, so Style/Colour/Gradient here only take
        -- effect when it's OFF (Size/Inset always apply).  Border Animation is
        -- intentionally omitted (same FPS rationale as the buff row).
        GUI:CreateBorderControls(borderGroup, db, "debuff", {
            parent        = self.child,
            include       = { inset = true, offset = true, blendMode = true,
                              gradient = true, shadow = true, alpha = true },
            sizeMin = 0, sizeMax = 8, sizeStep = 1,
            fullUpdate    = function() if DF.UpdateAllFrames then DF:UpdateAllFrames() end end,
            lightUpdate   = function() DF:LightweightUpdateAuraBorder("debuff") end,
            lightColors   = function() DF:LightweightUpdateAuraBorder("debuff") end,
            refreshStates = function() self:RefreshStates() end,
            disableWhen   = function(d) return not d.showDebuffs end,
        })
        -- These two are added to the box BY HAND, so the toolkit's disableWhen
        -- doesn't reach them — they carry the Debuffs-off grey themselves or the
        -- box would half-grey.
        local colorByType = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Color by Dispel Type"], db, "debuffBorderColorByType", InvalidateAndUpdate), 30)
        colorByType.disableOn = function(d) return not d.showDebuffs or not d.debuffShowBorder end
        -- 12.1 rows: the native dispel ring's inset (+ inward / - outward halo; the
        -- ring geometry is ours even though Blizzard tints it). Live via restyle.
        local dispelInset = borderGroup:AddWidget(GUI:CreateSlider(self.child, L["Dispel Border Inset"], -8, 8, 1, db, "debuffDispelBorderInset", nil, function() DF:LightweightUpdateAuraBorder("debuff") end, true), 55)
        dispelInset.disableOn = function(d) return not d.showDebuffs or not d.debuffBorderColorByType end
        dispelInset.hideOn = function(d) return not DF:FactoryOwnsDebuffRow(d) end
        dispelInset.tooltip = L["How far the dispel-type ring sits inside the icon edge. Negative values push it outward into a halo around the icon instead."]
        -- Colors-page link right under "Color by Dispel Type": the dispel-type palette
        -- lives on the account-wide Colors page (one shared set, also used by the Dispel
        -- Overlay). Co-located with its toggle so it's obvious where to edit the colours.
        local dispelColorsLink = GUI:CreateDispelColorsPageLink(self.child, 260)
        borderGroup:AddWidget(dispelColorsLink, (dispelColorsLink.layoutHeight or 16) + 2)
        -- ☠ COLUMN 1 — same call as the Buffs page, same reasoning, see the note there.
        -- This page is even more lopsided (939 of layout against 3229 of styling). Border
        -- lands under Position, which is where its size/inset/offset controls belong anyway.
        Add(borderGroup, nil, 1)

        -- Important Debuffs, built ~150 lines above. COLUMN 1, directly under Border: it is
        -- the OTHER whole-icon treatment on this page (a size step plus a corner marker),
        -- and it is the counterweight that lets Stack Count cross right to sit with Duration
        -- (458 out vs 413 in). Same seven-group column 1 as Buffs, which carries Pandemic in
        -- this slot. Column 2 is then purely the elements drawn on the icon.
        -- ⚠ Crossed to column 2. It sat in column 1 as this page's counterweight to the
        -- styling boxes on the right (same reasoning as the buff page's Border note) --
        -- but column 1 has since gained Debuff Filters, Debuff Blacklist and Order &
        -- Limits, so the imbalance it was correcting now runs the other way. Important
        -- Debuffs is a mark drawn ON the icon, so column 2 is also where this page's
        -- own doctrine puts it: the crossing was the exception, and it is no longer
        -- needed to buy anything.
        Add(impGroup, nil, 2)

        -- Duration Text Group (col2) — "Duration Text" for the same reason as Buffs.
        local durationGroup = GUI:CreateSettingsGroup(self.child, 280)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Text"]), 40)
        durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Duration"], db, "debuffShowDuration", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        -- Cooldown swipe (radial time-remaining) lives with Duration Text, not Border.
        durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Cooldown Swipe"], db, "debuffHideSwipe", nil), 30)
        -- Icon-sized formats only (see the buff page's Duration Format note).
        local debuffDurationFormatOptions = { NUMBER = L["Standard"], SHORT = L["Units"],
            TIMER = L["Timer"], PERCENT = L["Percent"],
            _order = { "NUMBER", "SHORT", "TIMER", "PERCENT" } }
        local durFormat = GUI:CreateDurationFormatControls(self.child, durationGroup, debuffDurationFormatOptions, db, "debuffDurationFormat", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames(); GUI:RefreshCurrentPage() end)
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
        AddColorsPageLink(durationGroup, self.child)
        -- Hide Above can't compose with the Percent format (see the buff page).
        local durHideAbove = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Above Threshold"], db, "debuffDurationHideAboveEnabled", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
        durHideAbove.disableOn = function(d) return not d.debuffShowDuration or DF:IsPercentDurationFormat(d.debuffDurationFormat) end
        local durHideAboveSlider = durationGroup:AddWidget(GUI:CreateSlider(self.child, L["Hide Above (seconds)"], 1, 60, 1, db, "debuffDurationHideAboveThreshold", nil, function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
        durHideAboveSlider.disableOn = function(d) return not d.debuffShowDuration or not d.debuffDurationHideAboveEnabled or DF:IsPercentDurationFormat(d.debuffDurationFormat) end
        local durHidePerm = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Duration on Permanent Auras"], db, "debuffDurationHideOnPermanent", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
        durHidePerm.disableOn = function(d) return not d.debuffShowDuration end
        -- Grey the whole group when Debuffs are off (composes with the per-control
        -- debuffShowDuration gates), matching Settings/Position/Grid.
        durationGroup.disableChildrenOn = function(d) return not d.showDebuffs end
        Add(durationGroup, nil, 2)

        -- Stack Count Group (col2) — directly under Duration, and in that order on every
        -- surface that has both: they are the two text elements on an icon and are tuned as
        -- a pair, so a user looking for one expects the other adjacent. Matches Buffs and
        -- the Aura Designer cards.
        local stackCountGroup = GUI:CreateSettingsGroup(self.child, 280)
        stackCountGroup:AddWidget(GUI:CreateHeader(self.child, L["Stack Count"]), 40)
        stackCountGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "debuffStackFont", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05, db, "debuffStackScale", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "debuffStackOutline", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "debuffStackOutline", function() DF:LightweightUpdateAuraStackText("debuff") end), 30)
        stackCountGroup:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "debuffStackAnchor", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -150, 150, 1, db, "debuffStackX", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -150, 150, 1, db, "debuffStackY", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "debuffStackColor", false, function() DF:LightweightUpdateAuraStackText("debuff") end, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 30)
        -- (No "Min Stacks to Show" — see the Buffs page for why it cannot exist on 12.1.)
        -- Grey the whole group when Debuffs are off, matching Settings/Position/Grid.
        stackCountGroup.disableChildrenOn = function(d) return not d.showDebuffs end
        Add(stackCountGroup, nil, 2)

        -- Dispel Text Group (col2, under Stack Count) — the dispel-type letters
        -- ("Ma", "Po", …), engine-written per aura (12.1 factory rows only; the
        -- legacy renderer has no source for them).
        -- ★ 2026-07-31: no longer requires Colorblind Mode. The bind passes
        -- customDispelTextMap, which takes Blizzard's direct SetText path instead of
        -- the CVar-gated one (DF:GetGameDispelTextMap, Frames/Border.lua) — so the
        -- old caution note and the CVar caveat in the tooltip are gone with it.
        -- Renamed from "Dispel Symbol" the same day: that read as the dispel ICON,
        -- which is a different native feature. DB keys stay debuffDispelSymbol*.
        -- ☠ Its hideOn makes this the one box on the page that can vanish, so it belongs in
        -- the SHORTER column: here it takes the page from 1972/1753 to 1972/2196 rather than
        -- lurching an already-long column by 443 every time the row backend changes.
        local symbolGroup = GUI:CreateSettingsGroup(self.child, 280)
        symbolGroup:AddWidget(GUI:CreateHeader(self.child, L["Dispel Text"]), 40)
        local symbolEnable = symbolGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Dispel Text"], db, "debuffDispelSymbolEnabled", function()
            self:RefreshStates()
            -- Region presence is structural (create-once) — full re-drive rebuilds the row.
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
        end), 30)
        symbolEnable.tooltip = L["Shows a short letter code on each debuff for its dispel type — Ma for Magic, Po for Poison, and so on. Uses the game's own wording for your language."]
        symbolEnable.keepEnabled = true
        symbolEnable.disableOn = function(d) return not d.showDebuffs end
        GUI:CreateTextControls(symbolGroup, db, "debuffDispelSymbol", {
            parent    = self.child,
            include   = { color = true },
            disableOn = function(d) return not d.debuffDispelSymbolEnabled end,
            onChange  = function() DF:InvalidateAuraLayout() end,
            onDrag    = function() DF:InvalidateAuraLayout() end,
        })
        symbolGroup.disableChildrenOn = function(d) return not d.showDebuffs end
        symbolGroup.hideOn = function(d) return not DF:FactoryOwnsDebuffRow(d) end
        Add(symbolGroup, nil, 2)

        -- ===== DURATION BAR ===== (12.1 factory rows only — mirrors the Buffs
        -- page's block; see there for the sig-split routing note)
        --
        -- The collapsible section used to carry this predicate and hide the bar
        -- with itself; with the section gone the box declares it directly.
        local function HideDurationBar(d) return not DF:FactoryOwnsDebuffRow(d) end

        local function DebuffBarChanged() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end

        local durBarGroup = GUI:CreateSettingsGroup(self.child, 280)
        durBarGroup.hideOn = HideDurationBar
        durBarGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Bar"]), 40)
        durBarGroup:AddWidget(GUI:CreateLabel(self.child, L["Shows a bar on each icon that drains with the aura's remaining time."], 250), 30)
        local debuffBarEnable = durBarGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Duration Bar"], db, "debuffDurationBarEnabled", function()
            self:RefreshStates()
            DebuffBarChanged()
        end), 30)
        debuffBarEnable.keepEnabled = true
        debuffBarEnable.disableOn = function(d) return not d.showDebuffs end
        durBarGroup.disableChildrenOn = function(d) return not d.showDebuffs or not d.debuffDurationBarEnabled end
        -- Where the bar sits, then what it looks like. One box rather than two:
        -- every other optional element on this page (Stack Count, Dispel Text)
        -- is a single box, and splitting only this one into geometry + style
        -- made the bar read as more of a feature than its neighbours while
        -- taking up half of column 2.
        durBarGroup:AddWidget(GUI:CreateDropdown(self.child, L["Position"], { BOTTOM = L["Bottom"], TOP = L["Top"] }, db, "debuffDurationBarPosition", DebuffBarChanged), 55)
        durBarGroup:AddWidget(GUI:CreateSlider(self.child, L["Height"], 1, 12, 1, db, "debuffDurationBarHeight", nil, DebuffBarChanged, true), 55)
        durBarGroup:AddWidget(GUI:CreateSlider(self.child, L["Gap"], 0, 10, 1, db, "debuffDurationBarGap", nil, DebuffBarChanged, true), 55)
        durBarGroup:AddWidget(GUI:CreateDropdown(self.child, L["Color Mode"], DF:GetDurationBarColorModes(), db, "debuffDurationBarColorMode", function()
            self:RefreshStates()
            DebuffBarChanged()
        end), 55)
        local debuffBarTex = durBarGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "debuffDurationBarTexture", DebuffBarChanged), 55)
        local debuffBarCol = durBarGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Bar Color"], db, "debuffDurationBarColor", true, DebuffBarChanged), 30)
        -- A curve mode brings its own ramp texture and forces white, so these two do
        -- nothing while it is selected - dim them rather than leave dead controls live.
        debuffBarTex.disableOn = function(d) return DF:IsDurationBarCurveMode(d.debuffDurationBarColorMode) end
        debuffBarCol.disableOn = debuffBarTex.disableOn
        durBarGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "debuffDurationBarBGColor", true, DebuffBarChanged), 30)
        durBarGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Fill"], db, "debuffDurationBarReverseFill", DebuffBarChanged), 30)
        Add(durBarGroup, nil, 2)

        -- (No Pandemic box here, unlike Buffs. This row shows harmful auras on a FRIENDLY
        -- unit — cast on your party by something else — which you cannot refresh, so they
        -- have no refresh window and the cue could never light. Controls wired to an
        -- impossibility are worse than no controls. See BuildAuraRowConfig in
        -- Features/Auras.lua for the render-side gate that matches this.)

        -- See Also links

        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_filterdesigner", label = L["Filter Designer"]},
            {pageId = "display_tooltips", label = L["Debuff Tooltips"]},
            {pageId = "general_integrations", label = L["Integrations"]},
            {pageId = "auras_dispel", label = L["Dispel Overlay"]},
        }), 30, "both")
    end)
    
    
    -- Auras > Missing Buffs
    local pageMissingBuffs = CreateSubTab("auras", "auras_missingbuffs", L["Missing Buffs"])
    BuildPage(pageMissingBuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"missingBuff"}, L["Missing Buffs"], "auras_missingbuffs"), 25, 2)
        
        
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
        local mbAutoDetect = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Auto-detect (your class's buff)"], db, "missingBuffClassDetection", function()
            self:RefreshStates()
            refreshMissing()
        end), 30)
        mbAutoDetect.tooltip = L["Watches whichever raid buff your own class provides, and follows you when you change character. Turn it off to pick the buffs to watch by hand below."]
        local mbHideFromBar = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Raid Buffs from Buff Bar"], db, "missingBuffHideFromBar", function()
            -- Factory: the exclusion is a structural candidate-filter on the BUFF row —
            -- refreshMissing's InvalidateAuraLayout re-drives it (sig change -> Rebuild).
            refreshMissing()
            DF:UpdateAllAuras()
        end), 30)
        mbHideFromBar.tooltip = L["Stops the raid buffs tracked here from also taking up a slot in the normal buff row, so the missing-buff icon is the only place they appear."]
        -- (No Debug Mode checkbox: its trace narrated the legacy UnitHasBuff scan, which
        -- never runs on the read-free 12.1 widget -- presence is never known to Lua, so
        -- there is nothing to print. Removed 2026-07-25 as its own comment long proposed.)
        Add(settingsGroup, nil, 1)
        
        -- ===== BUFFS TO CHECK GROUP (Column 1) =====
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
        Add(buffsGroup, nil, 1)
        
        -- ===== APPEARANCE GROUP (Column 2) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
        appearanceGroup.disableChildrenOn = HideMissingBuffOptions
        appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Icon Size"], 12, 48, 1, db, "missingBuffIconSize", function()
            refreshMissing()
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        appearanceGroup:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 3.0, 0.1, db, "missingBuffIconScale", function()
            refreshMissing()
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        appearanceGroup:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "missingBuffIconFrameLevel", function()
            refreshMissing()
        end, function() DF:LightweightUpdateFrameLevel("missingBuff") end, true)), 55)
        Add(appearanceGroup, nil, 2)
        
        -- ===== POSITION GROUP (Column 1) =====
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
        Add(positionGroup, nil, 1)
        
        -- ===== BORDER GROUP (Column 2) =====
        -- Stage 4.1: hand-rolled border block replaced by the unified helper.
        -- include set tailored for a "needs attention" alert: alpha / inset /
        -- offset / blendMode / gradient / shadow / animate (matches the
        -- Defensive Icon — Border Offset nudges the band relative to the icon).
        -- Class/Role colour offered too: the missing-buff icon sits on a unit
        -- frame, so its border can communicate WHOSE buff is missing at a glance.
        -- Skipped: colour-by-time / colour-by-type (no aura-state context here).
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        GUI:CreateBorderControls(borderGroup, db, "missingBuffIcon", {
            parent       = self.child,
            include      = { alpha = true, inset = true, offset = true, blendMode = true,
                             gradient = true, shadow = true, animate = true,
                             classColor = true, roleColor = true },
            fullUpdate   = function() refreshMissing() end,
            lightUpdate  = function() DF:LightweightUpdateMissingBuff() end,
            lightColors  = function() DF:LightweightUpdateMissingBuffBorderColor() end,
            refreshStates = function() self:RefreshStates() end,
            sizeMin = 0, sizeMax = 6, sizeStep = 1,  -- 0 = animation-only (no solid edge)
        })
        -- No hideWhen: the group gate below is what handles the feature being
        -- off, and it GREYS like every other box on this page. (This call used to
        -- pass both, so the controls vanished before the grey could show.)
        borderGroup.disableChildrenOn = HideMissingBuffOptions
        Add(borderGroup, nil, 2)
        
        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buff Bar"]},
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
        -- Copy button at top. defensiveFilterSelection is an exact-key entry
        -- (prefix matcher, see Profile.lua) so the category selection edited on
        -- this page rides this page's Copy/Sync/Reset. It is also registered on
        -- the Aura Filters page — overlap is fine, both DeepCopy the same value.
        -- "defensiveBar" covers the row's Layout box (Max / Growth / Spacing / Wrap),
        -- which none of the other prefixes reached.
        Add(CreateCopyButton(self.child, {"defensiveIcon", "defensiveFilterSelection", "defensiveSortOrder", "defensiveDurationBar", "defensiveBar"}, L["Defensive Icon"], "auras_defensiveicon"), 25, 2)
        
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

        -- Native rows only — the legacy fallback keeps its own fixed order.
        local defSortOptions = {
            DEFAULT = L["Default (Slot Order)"],
            TIME = L["Most Urgent"],
            EXTERNALS = L["Externals First"],
        }
        local defSortDrop = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, L["Sort Order"], defSortOptions, db, "defensiveSortOrder", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 55)
        defSortDrop.hideOn = function(d) return not DF:FactoryOwnsDefensiveRow(d) end
        defSortDrop.tooltip = L["Externals First: defensives cast on this player by others show first, their own last. Most Urgent: soonest to expire first."]

        local defWrap = layoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Icons Per Row"], 1, 5, 1, db, "defensiveBarWrap", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, nil, true), 55)
        -- Greys out on vertical-primary growth, where the native row-primary flow renders a
        -- single column and there is nothing for a per-row count to do. Normal contextual
        -- state via the grey seam, NOT a 12.1 frost — the control works horizontally, and the
        -- blocked registry is for things the game genuinely cannot do. Mirrors the Buffs page,
        -- including its 68914 re-verification of the flow-layout options.
        defWrap.disableOn = function(d)
            local g = d.defensiveBarGrowth or ""
            -- Vertical-primary AND vertical-centred growth both render a single column.
            return DF:FactoryOwnsDefensiveRow(d) and (g:sub(1, 2) == "UP" or g:sub(1, 4) == "DOWN"
                or g == "CENTER_LEFT" or g == "CENTER_RIGHT")
        end

        layoutGroup:AddWidget(GUI:CreateSlider(self.child, L["Spacing"], -10, 10, 1, db, "defensiveBarSpacing", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)

        Add(layoutGroup, nil, 1)

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

        appearanceGroup:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "defensiveIconFrameLevel", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateFrameLevel("defensive") end, true)), 55)

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
        GUI:CreateBorderControls(borderGroup, db, "defensiveIcon", {
            parent       = self.child,
            -- Class/Role colour makes sense here: at a glance, the border
            -- communicates WHO is using the defensive cooldown (their class
            -- or role) without the user having to read the icon. (Animation is
            -- not offered: the defensive icon is a container button, and 12.1
            -- forbids driving its border while auras are secret — see
            -- AuraContainer's animation chokepoint.)
            include      = { inset = true, offset = true, blendMode = true,
                             gradient = true, shadow = true, alpha = true,
                             classColor = true, roleColor = true },
            fullUpdate   = function() if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end end,
            lightUpdate  = function() DF:LightweightUpdateDefensiveIcons() end,
            lightColors  = function() DF:LightweightUpdateDefensiveIconColors() end,
            refreshStates = function() self:RefreshStates() end,
        })
        -- No hideWhen: the group gate below is what handles the feature being
        -- off, and it GREYS like every other box on this page. (This call used to
        -- pass both, so the controls vanished before the grey could show.)
        borderGroup.disableChildrenOn = HideDefensiveIconOptions
        Add(borderGroup, nil, 2)

        -- ===== DEFENSIVE FILTERS GROUP (Column 2) =====
        -- Category filter selection for the defensive row (Filter Registry
        -- presets + custom filters). Mirrors the Aura Filters page's buff
        -- selection list. Each row toggles a key inside
        -- db.defensiveFilterSelection — always mutate the inner tables in
        -- place (the aura pipeline holds references to them; never reassign).
        -- No Show All / Only Mine here: the defensive row resolves with
        -- showAll hard-false and has no such keys (see BuildDefensiveRowConfig).
        do
            local filterGroup = GUI:CreateSettingsGroup(self.child, 280)
            filterGroup:AddWidget(GUI:CreateHeader(self.child, L["Defensive Filters"]), 40)
            filterGroup.disableChildrenOn = HideDefensiveIconOptions

            -- Same sentence as the Buff Bar page's filter group, from one string:
            -- the two groups now do the same job for two consumers, and wording the
            -- rule twice is how they drift apart. It also drops "enabled" — the
            -- page's word for a checked box is "selected", everywhere.
            filterGroup:AddWidget(GUI:CreateLabel(self.child,
                "|cff888888" .. L["Selected filters are combined — a buff matching any of them is shown."] .. "|r", 250), 35)

            -- Rebuild the native filter strings and re-drive the container rows
            -- (same pair as the Aura Filters page's DirectFilterChanged — this
            -- page has no local equivalent).
            local function DefensiveFilterChanged()
                if DF.RebuildDirectFilterStrings then
                    DF:RebuildDirectFilterStrings()
                end
                if DF.InvalidateAuraLayout then
                    DF:InvalidateAuraLayout()
                end
            end

            local R = DF.FilterRegistry
            local function SelectionCheckbox(labelText, getSel, setSel)
                return filterGroup:AddWidget(GUI:CreateCheckbox(self.child, labelText, nil, nil, DefensiveFilterChanged, getSel, setSel), 30)
            end

            for _, cat in ipairs(R.Categories) do
                local key = cat.key
                local enabled, total = R:PresetCounts(key)
                local counts = R:IsPresetModified(key)
                    and format("(%d/%d, %s)", enabled, total, L["Modified"])
                    or  format("(%d/%d)", enabled, total)
                SelectionCheckbox(format("%s |cff888888%s|r", L[cat.name], counts),
                    function() return db.defensiveFilterSelection.presets[key] or false end,
                    function(v) db.defensiveFilterSelection.presets[key] = v or nil end)
            end

            -- Custom filters, sorted by name for a stable order (the store is id-keyed)
            local sortedCustoms = {}
            for cfId in pairs(R:ReadStore().customFilters) do
                sortedCustoms[#sortedCustoms + 1] = cfId
            end
            table.sort(sortedCustoms, function(a, b)
                local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
                local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
                if na ~= nb then return na < nb end
                return a < b
            end)
            for _, cfId in ipairs(sortedCustoms) do
                local f = R:GetCustomFilter(cfId)
                SelectionCheckbox(format("%s |c%s(%s)|r", f.name or cfId, GUI:ToneHex("info"), L["Custom"]),
                    function() return db.defensiveFilterSelection.customs[cfId] or false end,
                    function(v) db.defensiveFilterSelection.customs[cfId] = v or nil end)
            end

            -- Complement bucket: buffs that belong to no category
            SelectionCheckbox(L["Uncategorised Buffs"],
                function() return db.defensiveFilterSelection.uncategorised end,
                function(v) db.defensiveFilterSelection.uncategorised = v and true or false end)

            local defManage = filterGroup:AddWidget(GUI:CreateButton(self.child, L["Manage Filters"], 140, 22, function()
                if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
                    GUI.SelectTab("auras_filterdesigner")
                end
            end), 30)
            defManage.disableOn = function() return not (GUI.Pages and GUI.Pages["auras_filterdesigner"]) end

            -- The page build is cached across tab switches, but preset counts and
            -- the custom-filter list can change while this page is hidden (Filter
            -- Designer edits). On show, invalidate the page cache when the registry
            -- signature moved so RefreshCached() rebuilds fresh rows instead of
            -- serving stale ones (same idiom as the Aura Filters page).
            local function RegistrySignature()
                local parts = {}
                for _, cat in ipairs(R.Categories) do
                    local enabled, total = R:PresetCounts(cat.key)
                    parts[#parts + 1] = format("%s:%d/%d%s", cat.key, enabled, total,
                        R:IsPresetModified(cat.key) and "*" or "")
                end
                for cfId, f in pairs(R:ReadStore().customFilters) do
                    parts[#parts + 1] = cfId .. "=" .. (f.name or "")
                end
                table.sort(parts)
                return table.concat(parts, ";")
            end
            self.dfDefFilterSignature = RegistrySignature()
            if not self.dfDefFilterSigHooked then
                self.dfDefFilterSigHooked = true
                self:HookScript("OnShow", function(page)
                    if page.dfDefFilterSignature ~= RegistrySignature() then
                        page:Invalidate()
                    end
                end)
            end

            Add(filterGroup, nil, 2)
        end

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

        -- Duration Format (PTR-7 #5): previously hardcoded NUMBER; icon-sized
        -- formats only (see the buff page's Duration Format note). No Hide Above
        -- on this page, so no percent-grey needed.
        local defDurFormatOptions = { NUMBER = L["Standard"], SHORT = L["Units"],
            TIMER = L["Timer"], PERCENT = L["Percent"],
            _order = { "NUMBER", "SHORT", "TIMER", "PERCENT" } }
        -- One widget now, so hideOn covers the example too — no second predicate to keep
        -- in step (see CreateDurationFormatControls).
        local defDurFormat = GUI:CreateDurationFormatControls(self.child, durationGroup, defDurFormatOptions, db, "defensiveIconDurationFormat", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end)
        defDurFormat.hideOn = HideDefensiveDurationOptions

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
        local diColorsLink = AddColorsPageLink(durationGroup, self.child)
        diColorsLink.hideOn = HideDefensiveDurationOptions

        local diDurHidePerm = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Duration on Permanent Auras"], db, "defensiveIconDurationHideOnPermanent", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        diDurHidePerm.hideOn = HideDefensiveDurationOptions

        Add(durationGroup, nil, 1)

        -- (The old "Duration Position" group is gone: CreateTextControls above already
        -- renders Anchor + Offset X/Y on the same defensiveIconDurationX/Y keys — the
        -- separate group was a duplicate left behind by the TextStyle conversion.)

        -- ===== DURATION BAR GROUP (Column 1) ===== (12.1 factory rows only —
        -- mirrors the Buffs page's block; UpdateAllDefensiveBars bumps the layout
        -- version, and the sig split routes Rebuild vs in-place restyle)
        local durBarGroup = GUI:CreateSettingsGroup(self.child, 280)
        durBarGroup.hideOn = function(d) return not DF:FactoryOwnsDefensiveRow(d) end
        durBarGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Bar"]), 40)
        durBarGroup:AddWidget(GUI:CreateLabel(self.child, L["Shows a bar on each icon that drains with the aura's remaining time."], 250), 30)
        local function DefBarChanged()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end
        local defBarEnable = durBarGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Duration Bar"], db, "defensiveDurationBarEnabled", function()
            self:RefreshStates()
            DefBarChanged()
        end), 30)
        defBarEnable.keepEnabled = true
        defBarEnable.disableOn = HideDefensiveIconOptions
        durBarGroup.disableChildrenOn = function(d) return not d.defensiveIconEnabled or not d.defensiveDurationBarEnabled end
        durBarGroup:AddWidget(GUI:CreateDropdown(self.child, L["Position"], { BOTTOM = L["Bottom"], TOP = L["Top"] }, db, "defensiveDurationBarPosition", DefBarChanged), 55)
        durBarGroup:AddWidget(GUI:CreateSlider(self.child, L["Height"], 1, 12, 1, db, "defensiveDurationBarHeight", nil, DefBarChanged, true), 55)
        durBarGroup:AddWidget(GUI:CreateSlider(self.child, L["Gap"], 0, 10, 1, db, "defensiveDurationBarGap", nil, DefBarChanged, true), 55)
        durBarGroup:AddWidget(GUI:CreateDropdown(self.child, L["Color Mode"], DF:GetDurationBarColorModes(), db, "defensiveDurationBarColorMode", function()
            self:RefreshStates()
            DefBarChanged()
        end), 55)
        local defBarTex = durBarGroup:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "defensiveDurationBarTexture", DefBarChanged), 55)
        local defBarCol = durBarGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Bar Color"], db, "defensiveDurationBarColor", true, DefBarChanged), 30)
        -- A curve mode brings its own ramp texture and forces white, so these two do
        -- nothing while it is selected - dim them rather than leave dead controls live.
        defBarTex.disableOn = function(d) return DF:IsDurationBarCurveMode(d.defensiveDurationBarColorMode) end
        defBarCol.disableOn = defBarTex.disableOn
        durBarGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "defensiveDurationBarBGColor", true, DefBarChanged), 30)
        durBarGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Fill"], db, "defensiveDurationBarReverseFill", DefBarChanged), 30)
        Add(durBarGroup, nil, 1)

        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = L["Buff Bar"]},
            {pageId = "auras_debuffs", label = L["Debuff Bar"]},
            {pageId = "auras_filterdesigner", label = L["Filter Designer"]},
            {pageId = "general_integrations", label = L["Integrations"]},
        }), 30, "both")
    end)
    
    -- ========================================
    -- CATEGORY: Indicators
    -- ========================================
    CreateCategory("indicators", L["Indicators"])
    
    -- (Removed) Indicators > Targeted Spells. The group-frame display it
    -- configured is gone - Blizzard's 2026-04-07 UnitIsUnit hotfix removed the
    -- only way to tell which group member an enemy was casting at. The page had
    -- already been pulled from the sidebar; this removes the page itself, its
    -- api-blocked overlay, and GUI.RefreshTargetedSpellsOverlay (no callers).
    -- Personal Targeted and the Targeted List below are unaffected.

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
            tlHideOOC.tooltip = L["Hides the ambient spells idle NPCs cast while standing around: casts with no target, from an enemy that is not in combat. Casts aimed at you or a group member always show, so the opening cast of a pull is never hidden."]
            -- Game CVar, not a profile key — bound straight to the CVar via
            -- customGet/customSet so it cannot drift out of sync. See
            -- DF:SetNameplateOffscreen for why both features depend on it.
            local tlOffscreen = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Offscreen Nameplates"], nil, nil, nil,
                function() return DF:GetNameplateOffscreen() end,
                function(val) DF:SetNameplateOffscreen(val) end), 30)
            tlOffscreen.disableOn = HideTLOptions
            tlOffscreen.tooltip = L["Changes the Blizzard game setting 'nameplateShowOffscreen', which decides whether enemies outside your view still get a nameplate. This feature spots casts by watching the game's enemy nameplates, so with the setting off an enemy casting behind you is missed until you turn to face it — even if you have it targeted. Note that this is a game setting, not a DandersFrames one: it applies to your whole account and changes the game's nameplates everywhere."]
            local tlMaxBars = settingsGroup:AddWidget(GUI:CreateSlider(self.child, L["Max Bars"], 1, 20, 1, db, "targetedListMaxBars", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlMaxBars.disableOn = HideTLOptions
            Add(settingsGroup, nil, 1)



            local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
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
            Add(layoutGroup, nil, 1)

            local presetGroup = GUI:CreateSettingsGroup(self.child, 280)
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
            Add(presetGroup, nil, 2)



            local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
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
            Add(colorGroup, nil, 2)

            -- Border gets its own box, after Appearance (Bar Style + Bar Color)
            -- and before the element extras — the page-layout standard's column 2
            -- order. It used to be appended to the Bar Style box, where it read as
            -- part of the style preset it has nothing to do with.
            --
            -- Targeted List is a list view (N bars), so animate is deliberately
            -- skipped (per-bar animation would be visual noise + a perf hit).
            -- class/role colour skipped because the bars represent SPELLS, not
            -- units. colour-by-time / colour-by-type also skipped (no aura state).
            local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
            borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
            GUI:CreateBorderControls(borderGroup, db, "targetedList", {
                parent       = self.child,
                include      = { alpha = true, inset = true, blendMode = true,
                                 gradient = true, shadow = true },
                fullUpdate   = TargetedListUpdate,
                lightUpdate  = TargetedListUpdate,
                lightColors  = function() if DF.LightweightUpdateTargetedListBorderColor then DF:LightweightUpdateTargetedListBorderColor() end end,
                refreshStates = function() self:RefreshStates() end,
                sizeMin = 1, sizeMax = 6, sizeStep = 1,
                -- GREY, not hide: the rest of this page greys via
                -- disableOn = HideTLOptions, and the border block was the one
                -- thing that vanished instead.
                disableWhen  = HideTLOptions,
            })
            Add(borderGroup, nil, 2)

            local iconGroup = GUI:CreateSettingsGroup(self.child, 280)
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
            Add(iconGroup, nil, 2)



            local textToggleGroup = GUI:CreateSettingsGroup(self.child, 280)
            textToggleGroup:AddWidget(GUI:CreateHeader(self.child, L["Show Text"]), 40)
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
            Add(textToggleGroup, nil, 1)

            local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
            fontGroup:AddWidget(GUI:CreateHeader(self.child, L["Text Font"]), 40)
            local tlFont = fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "targetedListFont", TargetedListUpdate), 55)
            tlFont.disableOn = HideTLOptions
            local tlFontSize = fontGroup:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 8, 24, 1, db, "targetedListFontSize", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlFontSize.disableOn = HideTLOptions
            local tlFontOutline = fontGroup:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "targetedListFontOutline", TargetedListUpdate), 55)
            tlFontOutline.disableOn = HideTLOptions
            local tlFontShadow = fontGroup:AddWidget(GUI:CreateShadowCheckbox(self.child, L["Shadow"], db, "targetedListFontOutline", TargetedListUpdate), 30)
            tlFontShadow.disableOn = HideTLOptions
            Add(fontGroup, nil, 2)


            -- Per-element anchor + X/Y offset. Each text element
            -- (spell name, target name, duration) can be independently
            -- anchored to LEFT / CENTER / RIGHT within the bar's
            -- progress region with a pixel offset applied on top.

            local textAnchorOptions = { LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"] }
            local textAlignOptions = { LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"] }

            local spellNamePosGroup = GUI:CreateSettingsGroup(self.child, 280)
            spellNamePosGroup:AddWidget(GUI:CreateHeader(self.child, L["Spell Name Position"]), 40)
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
            Add(spellNamePosGroup, nil, 1)

            local targetNamePosGroup = GUI:CreateSettingsGroup(self.child, 280)
            targetNamePosGroup:AddWidget(GUI:CreateHeader(self.child, L["Target Name Position"]), 40)
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
            Add(targetNamePosGroup, nil, 2)

            local function HideDurationPosOptions(d) return not d.targetedListEnabled or not d.targetedListShowDuration end
            local durationPosGroup = GUI:CreateSettingsGroup(self.child, 280)
            durationPosGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Position"]), 40)
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
            Add(durationPosGroup, nil, 1)

            local interruptPosGroup = GUI:CreateSettingsGroup(self.child, 280)
            interruptPosGroup:AddWidget(GUI:CreateHeader(self.child, L["Interrupt Text Position"]), 40)
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
            Add(interruptPosGroup, nil, 2)



            local timingGroup = GUI:CreateSettingsGroup(self.child, 280)
            timingGroup:AddWidget(GUI:CreateHeader(self.child, L["Timing"]), 40)
            local tlFadeOut = timingGroup:AddWidget(GUI:CreateSlider(self.child, L["Fade Out Duration"], 0, 1, 0.05, db, "targetedListFadeOutDuration", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlFadeOut.disableOn = HideTLOptions
            local tlFlashDur = timingGroup:AddWidget(GUI:CreateSlider(self.child, L["Interrupted Flash Duration"], 0, 2, 0.1, db, "targetedListInterruptedFlashDuration", TargetedListUpdate, TargetedListUpdate, true), 55)
            tlFlashDur.disableOn = HideTLOptions
            Add(timingGroup, nil, 1)


            -- See Also links
            AddSpace(GUI.Space.block, "both")
            Add(GUI:CreateSeeAlso(self.child, {
                -- DEPRECATED-TARGETED-SPELLS: link dropped with the sidebar row.
                {pageId = "indicators_personal_targeted", label = L["Personal Targeted"]},
            }), 30, "both")
        end)

    -- Indicators > Personal Targeted Spells (center of screen display for player)
    local pagePersonalTargeted = CreateSubTab("indicators", "indicators_personal_targeted", L["Personal Targeted"])
    BuildPage(pagePersonalTargeted, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"personalTargeted"}, L["Personal Targeted"], "indicators_personal_targeted"), 25, 2)
        
        
        
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
        -- Same game CVar as the Targeted List page — Personal detects casts through
        -- nameplate tokens too (IsValidCasterUnit), so it has the identical
        -- offscreen blind spot. Both checkboxes drive the one CVar.
        local ptsOffscreen = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show Offscreen Nameplates"], nil, nil, nil,
            function() return DF:GetNameplateOffscreen() end,
            function(val) DF:SetNameplateOffscreen(val) end), 30)
        ptsOffscreen.disableOn = HidePersonalOptions
        ptsOffscreen.tooltip = L["Changes the Blizzard game setting 'nameplateShowOffscreen', which decides whether enemies outside your view still get a nameplate. This feature spots casts by watching the game's enemy nameplates, so with the setting off an enemy casting behind you is missed until you turn to face it — even if you have it targeted. Note that this is a game setting, not a DandersFrames one: it applies to your whole account and changes the game's nameplates everywhere."]
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
        -- No group-level hideOn: every checkbox in here already carries
        -- disableOn = HidePersonalOptions, so the box greys in place like the
        -- rest of the page instead of the whole column reflowing when the
        -- feature is switched off. (The per-checkbox hideOn for RAID mode
        -- stays — that one is about which mode you're in, not an off state.)
        Add(contentGroup, nil, 2)
        
        
        
        -- Size Group (col1)
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
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
        Add(sizeGroup, nil, 1)
        
        -- Growth Group (col2)
        local growthGroup = GUI:CreateSettingsGroup(self.child, 280)
        growthGroup:AddWidget(GUI:CreateHeader(self.child, L["Growth"]), 40)
        local ptsGrowth = growthGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growthOptions, db, "personalTargetedSpellGrowth", PersonalTargetedUpdate), 55)
        ptsGrowth.disableOn = HidePersonalOptions
        Add(growthGroup, nil, 1)
        
        
        
        -- Border Group (col1) — Stage 4.4: 3 hand-rolled border widgets
        -- (Show / Size / Color) replaced by CreateBorderControls. include
        -- set tailored for a "needs attention" alert surface (Personal
        -- Targeted = spells targeting you). Skipped: offset (icon has its
        -- own positioning), classColor / roleColor (spell alert, not unit
        -- identity), colorByTime / colorByType (no aura-state context).
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
        GUI:CreateBorderControls(borderGroup, db, "personalTargetedSpell", {
            parent       = self.child,
            include      = { alpha = true, inset = true, blendMode = true,
                             gradient = true, shadow = true, animate = true },
            fullUpdate   = PersonalTargetedUpdate,
            lightUpdate  = PersonalTargetedUpdate,
            lightColors  = PersonalTargetedUpdate,
            refreshStates = function() self:RefreshStates() end,
            -- GREY, not hide — every other control on this page greys via
            -- disableOn = HidePersonalOptions.
            disableWhen  = HidePersonalOptions,
            sizeMin = 0, sizeMax = 5, sizeStep = 1,  -- 0 = animation-only (no solid edge)
        })
        Add(borderGroup, nil, 2)
        
        -- Duration Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 280)
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
        Add(durationGroup, nil, 2)
        
        
        
        local function HidePersonalHighlightOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellHighlightImportant end

        local highlightGroup = GUI:CreateSettingsGroup(self.child, 280)
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
            disableWhen   = HidePersonalHighlightOptions,
            sizeMin = 0, sizeMax = 8, sizeStep = 1,
        })
        Add(highlightGroup, nil, 1)
        
        
        
        local function HideInterruptOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowInterrupted end
        local function HideInterruptXOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowInterrupted or not d.personalTargetedSpellInterruptedShowX end
        
        local interruptGroup = GUI:CreateSettingsGroup(self.child, 280)
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
        Add(interruptGroup, nil, 2)
        
        local xMarkGroup = GUI:CreateSettingsGroup(self.child, 280)
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
        -- No group-level hideOn: the three controls already grey via their own
        -- disableOn, so the box stays put when Show Interrupted Visual is off.
        Add(xMarkGroup, nil, 2)
        
        
        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            -- DEPRECATED-TARGETED-SPELLS: this used to point at Targeted Spells,
            -- which was the page's only link. Repointed rather than removed —
            -- Targeted List is the surviving answer to the same question ("what
            -- is being cast at my group"), and an empty See Also bar is worse
            -- than no bar.
            {pageId = "indicators_targetedlist", label = L["Targeted List"]},
        }), 30, "both")
    end)
    
    -- Indicators > Icons
    --
    -- ONE level of collapse on this page: the per-icon section header. Each
    -- section then holds plain boxes (Settings / Appearance / Position, plus
    -- Timer Text on AFK) that are always open.
    --
    -- Those boxes used to be collapsible too, each with its own collapseKey. It
    -- read as two levels of the same control -- expanding "Leader Icon" got you
    -- three more things to expand before you could see a setting -- and made a
    -- page of ordinary sliders feel deep. The section header is the only place
    -- a collapse earns its keep here, because that IS the choice being made:
    -- which icon am I configuring. Everything under it is one screen of rows.
    --
    -- Section headers are 280 wide to match the boxes; they were 270, which
    -- left the header bar visibly narrower than everything beneath it.
    --
    -- Their slot is 36 -- the same as every other collapsible section in the
    -- addon (28 of header + 8 of gap). It used to be 28, with the gap supplied
    -- by a spacer frame REGISTERED AS A SECTION CHILD, so the gap collapsed
    -- along with the section: correct while expanded, but this page defaults
    -- every section to collapsed, and 13 headers with no gap between them ran
    -- their borders together into one block. The gap belongs to the slot, not
    -- to the contents.
    local pageIcons = CreateSubTab("indicators", "indicators_icons", L["Icons"])
    DF._SetupGUIPagesPart5(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
end
