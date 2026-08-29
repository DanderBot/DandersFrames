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
                -- Mirror of the Show Buffs checkbox below, for its reason: the show/hide
                -- gate lives in the UNIT_AURA-driven UpdateAuras path, so a layout-only
                -- pass leaves the row in its previous state until the next aura event on
                -- that unit. EVERY writer of showBuffs needs this, not just the checkbox
                -- -- the Aura Designer's replace-buffs popup was the third writer and had
                -- the same gap (Krathe, 2026-08-19).
                DF:RefreshAllVisibleFrames()
            elseif data == "openAD" then
                if GUI.SelectTab then GUI.SelectTab("auras_auradesigner") end
            end
        end

        -- Refresh banner content based on current state
        adBanner.refreshContent = function(b, d)
            -- ☠ Per-MODE enable now, not the shared template's field (see
            -- DF:IsAuraDesignerEnabledForMode). Reading the preset made this banner
            -- follow whichever mode last toggled it.
            local adEnabled = DF.IsAuraDesignerEnabledForMode
                and DF:IsAuraDesignerEnabledForMode(((d == DF.db.raid) and "raid" or "party"))
            if adEnabled and d.showBuffs then
                b:SetHTML(L["Aura Designer is active alongside Buffs."] .. " " ..
                    adLink("openAD", L["Open Aura Designer"]), adOnLink)
            elseif adEnabled and not d.showBuffs then
                -- Two actions, so they need a conjunction: separated by a bare space
                -- and both in link colour, "Enable Buffs Open Aura Designer" read as
                -- a single link with a confusing name. Formatted rather than glued to
                -- an L["or"], so a translator controls word order and spacing instead
                -- of only the word.
                b:SetHTML(L["Buffs are disabled. Aura Designer is managing your auras."] .. " " ..
                    format(L["%s or %s"],
                        adLink("enableBuffs", L["Enable Buffs"]),
                        adLink("openAD", L["Open Aura Designer"])), adOnLink)
            end
        end

        adBanner.hideOn = function(d)
            return not (DF.IsAuraDesignerEnabledForMode
                and DF:IsAuraDesignerEnabledForMode(((d == DF.db.raid) and "raid" or "party")))
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
            -- hide when AD IS active
            return (DF.IsAuraDesignerEnabledForMode
                and DF:IsAuraDesignerEnabledForMode(((d == DF.db.raid) and "raid" or "party"))) and true or false
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

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: twelve 280 boxes in two columns, in
        -- the columns and the order they have always had -- including the two
        -- deliberate crossings the column notes below argue for.
        --
        -- POPOUT turns ELEVEN of them into feature rows in four bands, and the one
        -- single-setting group into a CONTROL ROW on the same plate:
        --
        --   "Content"   Visibility, Buff Filters, Order & Limits and the
        --               Hide Duplicate Buffs control row -- whether the bar exists,
        --               which buffs reach it, how many of them and in what order.
        --   "Icon"      Appearance, Layout, Position, Border -- the icon itself:
        --               how big, how they grid, where they sit, what rings them.
        --   "Text"      Duration Text, Stack Count -- the two things WRITTEN on an
        --               icon, which have always been tuned as a pair.
        --   headerless  Duration Bar, Pandemic -- the two 12.1-factory-only extras.
        --               ☠ NO HEADER, deliberately: both rows carry the same hideOn
        --               (no factory row, no bar and no refresh window), so a header
        --               would be a section title left standing over nothing on a
        --               client where neither row is drawn.
        --
        -- All three band headers are locale strings the page already ships.
        --
        -- Every converted group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates } and, where a toggle is hoisted,
        -- `hoistToggle`. The classic branch mounts the SAME builder into the box it
        -- always built, which is what makes "classic is unchanged" structural rather
        -- than a promise -- test_buffbar_page_builders.lua pins the inventory of each
        -- one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery: eager holders, pane reflow, the key claim,
        -- the amber tick, the footer's Reset Group / Hold: Defaults, the hoisted-toggle
        -- search repair, the control-row registration and the band width. nil in
        -- classic, which is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        local contentBand, iconBand, textBand, factoryBand
        if tools then
            contentBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            contentBand:AddWidget(GUI:CreateHeader(self.child, L["Content"]), 40)
            iconBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            iconBand:AddWidget(GUI:CreateHeader(self.child, L["Icon"]), 40)
            textBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            textBand:AddWidget(GUI:CreateHeader(self.child, L["Text"]), 40)
            factoryBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
        end

        -- ===== THE PAGE'S VOCABULARY AND ITS GATES, AT PAGE SCOPE =========
        -- These tables used to sit inside the box that offered them. The rows print
        -- the chosen value as their SUMMARY, and a summary is written OUTSIDE the
        -- group's builder -- so the word has to come out of the same table the
        -- dropdown offers, or a row could say one thing while the control behind it
        -- says another. (The Health Bar and Tooltips pages hoisted their dropdown
        -- tables for exactly this reason.)
        --
        -- ⚠ AND ABOVE EVERY BUILDER. A builder is a CLOSURE, and a closure captures
        -- the upvalue that exists when it is created -- so one declared above these
        -- lines would see nil rather than the table or the function.
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        local buffSortOptions = {
            DEFAULT = L["Default (Slot Order)"],
            TIME = L["Time Remaining"],
            NAME = L["Alphabetical"],
            APPLIED = L["Order Applied"],
            _order = { "DEFAULT", "TIME", "NAME", "APPLIED" },
        }
        -- Icon-sized formats only: Number "14" / Seconds "14s" / Percent "45%".
        -- FULL ("14 Seconds") overflows a 20px icon (never fit, delisted with #5's
        -- percent work — a saved FULL still renders until the user re-picks); the
        -- combined "12s (45%)" is AD-bar-only for the same reason.
        -- The icon rows carry the three time formats plus Percent; FULL and the percent
        -- composite stay on the Aura Designer bar, which has the width for them.
        local durationFormatOptions = { NUMBER = L["Standard"], SHORT = L["Units"],
            TIMER = L["Timer"], PERCENT = L["Percent"],
            _order = { "NUMBER", "SHORT", "TIMER", "PERCENT" } }
        local durBarPositionOptions = { BOTTOM = L["Bottom"], TOP = L["Top"] }

        local R = DF.FilterRegistry

        -- Rebuild the native filter strings and re-drive the container rows --
        -- the same pair the Aura Filters page ran on every tick, and the same
        -- one the Defensive Icon group uses.
        local function BuffFilterChanged()
            if DF.RebuildDirectFilterStrings then DF:RebuildDirectFilterStrings() end
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
        end
        local BuffOrderChanged = function()
            if DF.RebuildDirectFilterStrings then DF:RebuildDirectFilterStrings() end
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
        end
        -- Every bar edit routes through the factory drive: the sig split decides
        -- Rebuild (enable/position/height/gap — layout reservation) vs in-place
        -- restyle (texture/colours) — same callback either way.
        local function BuffBarChanged() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end
        -- ===== DURATION BAR / PANDEMIC ===== (12.1 factory rows only — the native
        -- container drains the strip render-side; the legacy renderer has no bar)
        --
        -- The collapsible section used to carry this predicate and hide the bar with
        -- itself; with the section gone the box declares it directly -- and in the
        -- popout layout it is the ROW's hideOn, so the band collapses the slot
        -- instead of drawing an empty plate.
        local function HideDurationBar(d) return not DF:FactoryOwnsBuffRow(d) end

        -- ☠ THE PAGE GATE, ON THE ROWS. Show Buffs greys every group it greyed in
        -- classic -- and ONLY those: the Buff Filters box and the Hide Duplicate
        -- Buffs box have never dimmed with it (you can pick what the bar would show
        -- before you switch it on), so their row and control row do not either.
        --
        -- ⚠ THE VISIBILITY ROW IS THE ONE EXCEPTION among the gated groups: it
        -- carries the gate's own tick, so greying it would leave no way to turn the
        -- bar back on.
        local function BuffsOffRow(d) return not (d or db).showBuffs end

        -- ☠ AND THE GROUP GATE SKIPS CHILD ONE, WHICH IN A PANE IS NOT A HEADER.
        -- DandersUI Sections' RefreshChildStates greys every child a
        -- disableChildrenOn covers EXCEPT index 1 -- correct for a page box, whose
        -- first child is always the header, and wrong for a popout pane, which has no
        -- header at all. The Pet Frames / Resource Bar answer, verbatim: spelled onto
        -- the widget itself, composed with whatever predicate it already carries, and
        -- applied at the MOUNT rather than inside the builder. Never runs in classic,
        -- where the box's own header is index 1.
        --
        -- Only the three panes whose first child is a GATED CONTROL need it. A pane
        -- opening on a label (Duration Bar, Pandemic) or on a control carrying its
        -- own disableOn (Visibility, Appearance, Layout, Position) already greys.
        local function GatePaneFirstChild(group)
            local entry = group and group.groupChildren and group.groupChildren[1]
            local w = entry and entry.widget
            if not w then return end
            local prev = w.disableOn
            w.disableOn = function(d) return BuffsOffRow(d) or (prev and prev(d)) or false end
        end

        -- The summary convention, once: at most four items, a fixed order,
        -- "\194\183" between them, WORDS localised and numbers raw, every read
        -- guarded because a profile mid-migration may be missing any of these keys.
        local function Join(parts) return table.concat(parts, " \194\183 ") end

        -- ===== VISIBILITY (a 280 box in column 1 in classic, the Content band's
        -- first row) =====
        -- Show Buffs is the master switch for this whole page — every other group
        -- greys out under it — so it leads, above even the filters. It used to sit
        -- fourth, below Filters / Order & Limits / Deduplication, where the one
        -- control that decides whether the bar exists at all was the hardest thing
        -- on the page to find.
        --
        -- Named for what the box DOES, not "Settings": everything on the page is a
        -- setting, and a generic label is worst exactly where this one now sits.
        -- "Visibility" covers both controls honestly — whether the bar shows at all,
        -- and how many icons of it you get — and stays clear of Appearance, which is
        -- styling.
        --
        -- ☠ ONE CONTROL BEHIND THE TICK, AND IT IS STILL A ROW RATHER THAN TWO
        -- CONTROL ROWS. A pane holding one slider is thin, but the row is not there
        -- for the slider: it is where the page's master switch lives, and a control
        -- row carries a setting rather than a group -- so it can offer neither the
        -- pair's Reset Group nor the tick that says the pair has been touched.
        -- Splitting them would also leave the page gate belonging to no row at all,
        -- which is the Pet Frames shape and was right THERE because that group's
        -- pane would have held nothing but a blurb.
        local function BuildVisibilityGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the ROW carries this tick. Still built in classic,
            -- where it is the page's only on/off control.
            if not tools2.hoistToggle then
                local showBuffsCb = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Buffs"], db, "showBuffs", function()
                    tools2.refreshStates()
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
            end

            local buffMax = group:AddWidget(GUI:CreateSlider(parent, L["Max Buffs"], 0, 8, 1, db, "buffMax", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            buffMax.disableOn = function(d) return not d.showBuffs end
        end

        -- What the whole page's gate costs when it moves, named once: the state pass,
        -- the aura re-scan the suppressed checkbox ran, and a repaint of every pane
        -- standing open -- eleven of which grey with it.
        local function OnShowBuffsToggle()
            self:RefreshStates()
            DF:RefreshAllVisibleFrames()
            if tools then tools.ReflowMounted() end
        end

        local function VisibilitySummary(d)
            if not d then return "" end
            local n = tonumber(d.buffMax)
            if not n then return "" end
            return format("%s %d", L["Max Buffs"], n)
        end

        if classicLayout then
            local visibilityGroup = GUI:CreateSettingsGroup(self.child, 280)
            visibilityGroup:AddWidget(GUI:CreateHeader(self.child, L["Visibility"]), 40)
            BuildVisibilityGroup({
                group = visibilityGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(visibilityGroup, nil, 1)
        else
            -- One: Max Buffs. The Show Buffs tick is HOISTED onto the row, so it is
            -- not one of them.
            local VISIBILITY_COUNT = 1

            local visMount, visContent = tools.PopoutContent(function(group, holder, reflow)
                BuildVisibilityGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local visRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Visibility"],
                db       = tools.RowDB,
                toggle   = { key = "showBuffs" },
                summary  = VisibilitySummary,
                count    = VISIBILITY_COUNT,
                onToggle = OnShowBuffsToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = visMount,
            }))
            tools.ClaimKeys(visRow, visContent)
            tools.WireModifiedTick(visRow)
            tools.WireFooter(visRow, function() DF:RefreshAllVisibleFrames() end)
            tools.RegisterHoistedToggle(visRow, L["Show Buffs"], "showBuffs", OnShowBuffsToggle)
        end

        -- ===== BUFF FILTERS (a 280 box in column 1 in classic, the Content band's
        -- second row) =====
        -- WHICH auras reach this bar, moved here from the Aura Filters page so that
        -- every consumer picks its own filters in its own place and Aura Filters is
        -- purely where filters are BUILT. The Defensive Icon has always worked this
        -- way; this makes the buff bar match it instead of being the one exception.
        --
        -- It sits directly under Visibility, above Order & Limits and Deduplication:
        -- once the bar is switched on, what it CONTAINS is the next question, and
        -- everything below decides how that content looks.
        --
        -- ⚠ The rows are the same three kinds the Aura Filters page listed, in the
        -- same order: built-in presets, then custom filters, then the complement
        -- bucket. Reordering them here would make the two pages disagree about what
        -- the library looks like.

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
        -- All Buffs overrides the whole list, so every row below it greys while
        -- it is on -- the same relationship the two had on the old page.
        local function ShowAllOn() return (db.directBuffShowAll) and true or false end

        -- This page's build is cached across tab switches, but preset counts and
        -- the custom-filter list change on the Aura Filters page while this one
        -- is hidden. Invalidate on show when the registry signature moved, so
        -- the rows rebuild instead of serving a stale list. Same idiom, and the
        -- same reason, as the Defensive Icon group.
        --
        -- ⚠ AT PAGE SCOPE, OUTSIDE THE BUILDER. A pane is built once per INSTANCE
        -- (pin a panel and open the row again and there are two), and this block is
        -- about the PAGE -- one signature, one hook. Inside the builder the guard
        -- would still hold, but the signature would be re-taken by whichever
        -- instance built last for no reason.
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

        -- ☠ THE ONE ROW ON THE PAGE WHOSE COUNT IS DATA. The pane mounts one tick per
        -- built-in category and one per custom filter the user has made, so the
        -- declared number has to be COUNTED rather than written down -- a literal
        -- would be wrong the moment somebody saves a filter.
        local function BuffFilterCount()
            local customs = 0
            for _ in pairs(R:ReadStore().customFilters) do customs = customs + 1 end
            -- Two scope switches, the rule, the caption that describes the list, the
            -- complement bucket, the tracking count and Manage Filters -- plus one row
            -- per category and one per custom filter.
            return 7 + #R.Categories + customs
        end

        -- What the row says with the panel shut: how much of the library is switched
        -- on, in the "11/13" shape the Resource Bar's class filter row uses, and the
        -- one scope switch that changes the meaning of all of it. All Buffs overrides
        -- the list outright, so it is named instead of the fraction rather than
        -- beside it.
        local function BuffFilterSummary(d)
            if not d then return "" end
            local parts = {}
            if d.directBuffShowAll then
                parts[#parts + 1] = L["All Buffs"]
            else
                local sel = d.buffFilterSelection or {}
                local presets, customs = sel.presets or {}, sel.customs or {}
                local on, total = 0, #R.Categories + 1   -- + the complement bucket
                for _, cat in ipairs(R.Categories) do
                    if presets[cat.key] then on = on + 1 end
                end
                for cfId in pairs(R:ReadStore().customFilters) do
                    total = total + 1
                    if customs[cfId] then on = on + 1 end
                end
                if sel.uncategorised then on = on + 1 end
                parts[#parts + 1] = format("%d/%d", on, total)
            end
            if d.directBuffOnlyMine then parts[#parts + 1] = L["Only My Buffs"] end
            return Join(parts)
        end

        local function BuildBuffFilterGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local showAllCb = group:AddWidget(GUI:CreateCheckbox(parent, L["All Buffs"], db, "directBuffShowAll", function()
                tools2.refreshStates()
                BuffFilterChanged()
            end), 30)
            -- ☠ `.tooltip` IS THE BODY, not the title. ResolveTooltipSpec
            -- (DandersFrames/GUI/Widgets.lua) turns a string .tooltip into
            -- { title = the widget's own label, lines = { it } } -- and it never reads
            -- .tooltipDesc at all. Setting .tooltip to the LABEL therefore rendered the
            -- label twice and threw the explanation away, on every one of these.
            showAllCb.tooltip = L["Show every buff with no filtering."]

            local onlyMineCb = group:AddWidget(GUI:CreateCheckbox(parent, L["Only My Buffs"], db, "directBuffOnlyMine", function()
                BuffFilterChanged()
            end), 30)
            onlyMineCb.tooltip = L["Only show buffs that you cast. Applies to all buff filters."]

            -- ⚠ A rule between the two SCOPE switches above and the filter list below.
            -- They are not filters: All Buffs overrides the whole list and Only My
            -- Buffs modifies all of it, so sharing the list's row height and checkbox
            -- made them read as two more filters you could pick. The old page drew its
            -- own divider for exactly this; this is the same fix with the shared
            -- widget (GUI:CreateSeparator, lifted out of the Blizzard Frames group).
            group:AddWidget(GUI:CreateSeparator(parent), 14)

            -- ⚠ BELOW the rule, not under the header. This sentence is about how the
            -- FILTER ROWS combine, and above the rule it sat over the two scope
            -- switches -- which do not combine with anything and are precisely what
            -- the rule separates out. A caption describing a list belongs inside that
            -- list's half of the group.
            --
            -- (The Defensive Icon's copy of this line does sit under its header, and
            -- correctly: that group has no scope switches, so its header and its rows
            -- are already adjacent.)
            group:AddWidget(GUI:CreateLabel(parent,
                "|cff888888" .. L["Selected filters are combined — a buff matching any of them is shown."] .. "|r", 250), 35)

            local function SelectionCheckbox(labelText, getSel, setSel)
                local cb = group:AddWidget(GUI:CreateCheckbox(parent, labelText, nil, nil,
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
            uncatCb.tooltip = L["Buffs that belong to none of the filters above."]

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
            local countLabel = group:AddWidget(GUI:CreateLabel(parent, "", 250), 24)
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

            -- ⚠ A PANE THE USER LEAVES THROUGH. Manage Filters is a tab switch, which
            -- rebuilds the page it lands on -- and CreatePopoutPageTools' own prologue
            -- closes every open panel on the way into that build. So the panel this
            -- button was clicked in is taken down by the page it opens, in the one
            -- order that is safe: the row it was wired to is still alive when it goes.
            local manageBtn = group:AddWidget(GUI:CreateButton(parent, L["Manage Filters"], 140, 22, function()
                if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
                    GUI.SelectTab("auras_filterdesigner")
                end
            end), 30)
            manageBtn.disableOn = function() return not (GUI.Pages and GUI.Pages["auras_filterdesigner"]) end
        end

        if classicLayout then
            local filterGroup = GUI:CreateSettingsGroup(self.child, 280)
            filterGroup:AddWidget(GUI:CreateHeader(self.child, L["Buff Filters"]), 40)
            BuildBuffFilterGroup({
                group = filterGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(filterGroup, nil, 1)
        else
            local filterMount, filterContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffFilterGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local filterRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Buff Filters"],
                db      = tools.RowDB,
                summary = BuffFilterSummary,
                count   = BuffFilterCount(),
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = filterMount,
            }))
            -- ⚠ THE SELECTION TABLE IS NAMED, because the walk cannot see it. Every
            -- filter tick is a CUSTOM get/set checkbox -- it has no db binding at all,
            -- so what it registers with search is a synthetic `custom_<label>` key and
            -- the real setting, `buffFilterSelection`, is bound to nothing the walk can
            -- find. Named through `extra`, the amber tick asks about the table the user
            -- is actually editing. (The synthetic keys ride along in the claim and the
            -- defaults engine has no answer for them, which is exactly what it does
            -- with them: nothing.)
            tools.ClaimKeys(filterRow, filterContent, { "buffFilterSelection" })
            tools.WireModifiedTick(filterRow)
            -- ☠ NO FOOTER ON THIS ROW, AND IT IS A REFUSAL RATHER THAN AN OMISSION.
            -- Reset Group writes `db[key] = DeepCopy(default)` (GUI/GroupActions.lua),
            -- which for buffFilterSelection REPLACES the table -- and the note at the
            -- top of this group says why that cannot happen: the aura pipeline holds
            -- references to that table and its inner tables, so a fresh one strands
            -- every holder. Hold: Defaults is the same write twice over. The Resource
            -- Bar's class filter refused a footer for the milder version of this (the
            -- thirteen bound ticks detach); here it would break the render path, and
            -- classic never offered a reset for this box either.
        end

        -- ⚠ ONE SIGNATURE AND ONE HOOK PER PAGE BUILD, in both layouts. The block runs
        -- after whichever arm built the list, exactly where it ran when the list was
        -- straight-line code inside the box.
        self.dfBuffFilterSignature = RegistrySignature()
        if not self.dfBuffFilterSigHooked then
            self.dfBuffFilterSigHooked = true
            self:HookScript("OnShow", function(page)
                if page.dfBuffFilterSignature ~= RegistrySignature() then
                    page:Invalidate()
                end
            end)
        end

        -- ===== ORDER & LIMITS (a 280 box in column 1 in classic, the Content band's
        -- third row) =====
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
        --
        -- ☠ NO TICK TO HOIST. Nothing here is the group's on/off: Hide Long Buffs
        -- gates one slider and nothing else, and Sort Order is a pick rather than a
        -- switch. This is a WAY IN, the Frame Fade / Out of Range shape.
        local function BuildBuffOrderGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Same gate as its siblings on this page.
            group.disableChildrenOn = function(d) return not d.showBuffs end

            group:AddWidget(GUI:CreateDropdown(parent, L["Sort Order"], buffSortOptions, db, "directBuffSortOrder", function()
                BuffOrderChanged()
                tools2.refreshStates()   -- Mine First greys while Sort Order = Default
            end), 55)

            -- Sort refinements (native rows only — the legacy Lua scan doesn't read them)
            local bfSortMine = group:AddWidget(GUI:CreateCheckbox(parent, L["My Auras First"], db, "directBuffSortMineFirst", BuffOrderChanged), 30)
            bfSortMine.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfSortMine.disableOn = function(d) return not DF:SortOrderSupportsMineFirst(d.directBuffSortOrder) end
            bfSortMine.tooltip = L["Sort your own auras before other players'. Unavailable on Default (which already shows yours first) and on Order Applied (which keeps one fixed order)."]
            local bfSortRev = group:AddWidget(GUI:CreateCheckbox(parent, L["Reverse Order"], db, "directBuffSortReverse", BuffOrderChanged), 30)
            bfSortRev.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfSortRev.tooltip = L["Reverse the sort direction."]

            -- Native-only: max TOTAL duration filter (12.1 candidateFilters.maxDuration).
            -- Hidden while the legacy render owns the row (not expressible there).
            local bfMaxDur = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Long Buffs"], db, "buffMaxDurationEnabled", function()
                BuffOrderChanged()
                tools2.refreshStates()
            end), 30)
            bfMaxDur.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfMaxDur.tooltip = L["Hide buffs whose total duration is longer than the threshold - e.g. hour-long food and flask buffs. Buffs with no duration (permanent auras) are also hidden while this is on."]
            local bfMaxDurSlider = group:AddWidget(GUI:CreateSlider(parent, L["Hide Longer Than (minutes)"], 1, 30, 1, db, "buffMaxDurationMinutes", nil, BuffOrderChanged), 55)
            bfMaxDurSlider.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfMaxDurSlider.disableOn = function(d) return not d.buffMaxDurationEnabled end

            -- Independent of Hide Long Buffs — but subsumed by it (a finite cap already
            -- rejects duration-0 auras), hence the tooltip honesty.
            local bfHidePerm = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Permanent Auras"], db, "buffHidePermanent", BuffOrderChanged), 30)
            bfHidePerm.hideOn = function(d) return not DF:FactoryOwnsBuffRow(d) end
            bfHidePerm.tooltip = L["Hide buffs with no duration, such as auras that last until cancelled. Hide Long Buffs also hides these while it is on."]
        end

        -- What sorting is doing, in the dropdown's own words, plus the one refinement
        -- that reverses everything it just said.
        local function BuffOrderSummary(d)
            if not d then return "" end
            local parts = {}
            local sort = buffSortOptions[d.directBuffSortOrder]
            if sort then parts[#parts + 1] = sort end
            if d.directBuffSortReverse then parts[#parts + 1] = L["Reverse Order"] end
            return Join(parts)
        end

        if classicLayout then
            local buffOrderGroup = GUI:CreateSettingsGroup(self.child, 280)
            buffOrderGroup:AddWidget(GUI:CreateHeader(self.child, L["Order & Limits"]), GUI.RowHeight.sectionHeader)
            BuildBuffOrderGroup({
                group = buffOrderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(buffOrderGroup, nil, 1)
        else
            -- Six: the sort pick, its two refinements, the long-buff pair and the
            -- permanent-aura tick.
            local BUFF_ORDER_COUNT = 6

            local orderMount, orderContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffOrderGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local orderRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Order & Limits"],
                db      = tools.RowDB,
                summary = BuffOrderSummary,
                count   = BUFF_ORDER_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = orderMount,
            }))
            tools.ClaimKeys(orderRow, orderContent)
            tools.WireModifiedTick(orderRow)
            tools.WireFooter(orderRow, BuffOrderChanged)
            orderRow.disableOn = BuffsOffRow
        end

        -- ===== DEDUPLICATION (a 280 box in column 1 in classic, a CONTROL ROW in the
        -- Content band here) =====
        -- The 12.1 alert banner that used to sit here is gone: both halves of the
        -- toggle are expressible again (Aura Designer via excludeSpellIDs, the
        -- Defensive Bar via its own resolved spell-ID map or a negated category —
        -- see BuildDirectBuffFilters / BuildAuraRowConfig), and the multi-filter
        -- duplicate it warned about cannot happen on a single-group buff row.
        -- What the checkbox does now fits a tooltip; a danger banner would read as
        -- "something is broken here".
        --
        -- ⚠ ONE SETTING IS A CONTROL ROW -- not a pane, which would be a click that
        -- buys one tick, and not a 280 box either, which is the one shape a column of
        -- full-width plates cannot absorb.
        --
        -- ⚠ AND THE ROW IS NAMED FOR THE SETTING, NOT FOR THE BOX. The Self Position
        -- rule read the other way round: of "Deduplication" and "Hide Duplicate
        -- Buffs", the one that survives standing alone on a plate is the sentence,
        -- not the jargon -- and naming it that keeps the search result identical in
        -- both layouts, because it is the caption the classic checkbox registers.
        local function DedupChanged()
            -- Bump the aura layout version so the factory buff row rebuilds with the new
            -- exclusion set (InvalidateAuraLayout -> RefreshFactoryRows -> DriveBuffFactory);
            -- UpdateAllAuras re-scans for the legacy (pre-12.1) dedup path.
            DF:InvalidateAuraLayout()
            DF:UpdateAllAuras()
        end
        local DEDUP_TIP = L["Hides buffs that are already shown elsewhere — by an Aura Designer indicator, or on the Defensive Bar — so they don't appear twice."]

        if classicLayout then
            local dedupGroup = GUI:CreateSettingsGroup(self.child, 280)
            dedupGroup:AddWidget(GUI:CreateHeader(self.child, L["Deduplication"]), 40)
            local dedupCb = GUI:CreateCheckbox(self.child, L["Hide Duplicate Buffs"], db, "buffDeduplicateDefensives", DedupChanged)
            dedupCb.tooltip = DEDUP_TIP
            dedupGroup:AddWidget(dedupCb, 30)
            Add(dedupGroup, nil, 1)
        else
            local dedupRow = contentBand:AddWidget(GUI:CreateControlRow(self.child, {
                label     = L["Hide Duplicate Buffs"],
                kind      = "checkbox",
                -- The FUNCTION form: the table is re-resolved on each read, so a mode
                -- switch is followed rather than frozen at whichever table this build
                -- captured.
                db        = tools.RowDB,
                key       = "buffDeduplicateDefensives",
                onChanged = DedupChanged,
                tooltip   = DEDUP_TIP,
            }))
            -- No slot height: the factory owns it (fixedRowHeight + preferredHeight
            -- are the popout row's own slot), which is what makes a control row and a
            -- feature row share one rhythm in a band.
            tools.RegisterControlRow(dedupRow, "checkbox", "buffDeduplicateDefensives", false, DedupChanged)
        end

        -- ===== APPEARANCE (a 280 box in column 2 in classic, the Icon band's first
        -- row) =====
        -- Icon Size / Scale / Alpha are how the row LOOKS, so they sit with the other
        -- styling, matching Missing Buffs and Defensive Icon. They used to live in
        -- Settings above, which made this the only aura family where the same three
        -- sliders were classed as geometry.
        local function ApplyBuffPosition() DF:LightweightUpdateAuraPosition("buff") end

        local function BuildBuffAppearanceGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local buffSize = group:AddWidget(GUI:CreateSlider(parent, L["Icon Size"], 10, 40, 1, db, "buffSize", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
            buffSize.disableOn = function(d) return not d.showBuffs end
            local buffScale = group:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.0, 0.05, db, "buffScale", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
            buffScale.disableOn = function(d) return not d.showBuffs end
            local buffAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0.0, 1.0, 0.05, db, "buffAlpha", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
            buffAlpha.disableOn = function(d) return not d.showBuffs end
        end

        -- Pixels first, then the two multipliers, and each only while it is doing
        -- something -- a row reading "Scale 1.00 · Alpha 1.00" on every default
        -- profile is noise (the Resource Bar border row's rule).
        local function BuffAppearanceSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.buffSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local scale = tonumber(d.buffScale)
            if scale and scale ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Scale"], scale) end
            local alpha = tonumber(d.buffAlpha)
            if alpha and alpha < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], alpha) end
            return Join(parts)
        end

        if classicLayout then
            local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
            appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
            BuildBuffAppearanceGroup({
                group = appearanceGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(appearanceGroup, nil, 2)
        else
            -- Three: size, scale, alpha.
            local BUFF_APPEARANCE_COUNT = 3

            local appearanceMount, appearanceContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffAppearanceGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local appearanceRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Appearance"],
                db      = tools.RowDB,
                summary = BuffAppearanceSummary,
                count   = BUFF_APPEARANCE_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = appearanceMount,
            }))
            tools.ClaimKeys(appearanceRow, appearanceContent)
            tools.WireModifiedTick(appearanceRow)
            tools.WireFooter(appearanceRow, ApplyBuffPosition)
            appearanceRow.disableOn = BuffsOffRow
        end

        -- ===== LAYOUT (a 280 box in column 1 in classic, the Icon band's second
        -- row) =====
        local function BuildBuffLayoutGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local buffWrap = group:AddWidget(GUI:CreateSlider(parent, L["Icons Per Row"], 1, 8, 1, db, "buffWrap", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
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
            --
            -- ☠ AND THE GROWTH IT READS IS SET IN ANOTHER PANE. Position owns buffGrowth;
            -- the growth control's own write ends in a page state pass, and ReflowMounted
            -- carries that to every pane standing open, so this slider re-gates from the
            -- next row down exactly as it did from the next box across.
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
            local buffPaddingX = group:AddWidget(GUI:CreateSlider(parent, L["Spacing X"], -5, 10, 1, db, "buffPaddingX", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
            buffPaddingX.disableOn = function(d) return not d.showBuffs end
            local buffPaddingY = group:AddWidget(GUI:CreateSlider(parent, L["Spacing Y"], -5, 10, 1, db, "buffPaddingY", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
            buffPaddingY.disableOn = function(d) return not d.showBuffs end
        end

        local function BuffLayoutSummary(d)
            if not d then return "" end
            local n = tonumber(d.buffWrap)
            if not n then return "" end
            return format("%s %d", L["Icons Per Row"], n)
        end

        if classicLayout then
            local gridGroup = GUI:CreateSettingsGroup(self.child, 280)
            gridGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout"]), 40)
            BuildBuffLayoutGroup({
                group = gridGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(gridGroup, nil, 1)
        else
            -- Three: icons per row and the two spacings.
            local BUFF_LAYOUT_COUNT = 3

            local layoutMount, layoutContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffLayoutGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local layoutRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Layout"],
                db      = tools.RowDB,
                summary = BuffLayoutSummary,
                count   = BUFF_LAYOUT_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = layoutMount,
            }))
            tools.ClaimKeys(layoutRow, layoutContent)
            tools.WireModifiedTick(layoutRow)
            tools.WireFooter(layoutRow, ApplyBuffPosition)
            layoutRow.disableOn = BuffsOffRow
        end

        -- ===== POSITION (a 280 box in column 1 in classic, the Icon band's third
        -- row) =====
        local function BuildBuffPositionGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local buffAnchor = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "buffAnchor", nil), 55)
            buffAnchor.disableOn = function(d) return not d.showBuffs end
            local buffGrowth = group:AddWidget(GUI:CreateGrowthControl(parent, db, "buffGrowth", nil), 155)
            buffGrowth.disableOn = function(d) return not d.showBuffs end
            local buffOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, db, "buffOffsetX", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
            buffOffsetX.disableOn = function(d) return not d.showBuffs end
            local buffOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, db, "buffOffsetY", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
            buffOffsetY.disableOn = function(d) return not d.showBuffs end
        end

        local function BuffPositionSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.buffAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local x, y = tonumber(d.buffOffsetX) or 0, tonumber(d.buffOffsetY) or 0
            if x ~= 0 or y ~= 0 then parts[#parts + 1] = format("%d, %d", x, y) end
            return Join(parts)
        end

        if classicLayout then
            local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
            positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
            BuildBuffPositionGroup({
                group = positionGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(positionGroup, nil, 1)
        else
            -- Four: the anchor, the growth control (one widget, three stacked mini
            -- dropdowns inside it) and the two offsets.
            local BUFF_POSITION_COUNT = 4

            local positionMount, positionContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffPositionGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local positionRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Position"],
                db      = tools.RowDB,
                summary = BuffPositionSummary,
                count   = BUFF_POSITION_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = positionMount,
            }))
            -- ⚠ buffGrowth IS NAMED, because the walk cannot see it. The growth control
            -- is three hand-built mini dropdowns in a container -- it registers nothing
            -- with search and carries no dbKey -- so without this the row's tick and its
            -- Reset Group would both act as though the setting were on another page.
            -- (Its repaint after a reset is covered: the container's refreshContent
            -- re-decomposes the stored value, and RefreshChildStates runs it on every
            -- reflow.)
            tools.ClaimKeys(positionRow, positionContent, { "buffGrowth" })
            tools.WireModifiedTick(positionRow)
            tools.WireFooter(positionRow, function() DF:UpdateAll() end)
            positionRow.disableOn = BuffsOffRow
        end

        -- ===== BORDER (a 280 box in column 1 in classic, the Icon band's fourth
        -- row) =====
        -- Full border toolkit via the unified helper (Stage 5.5 Phase 2).  No
        -- class/role colour (aura indicators aren't unit-class).  Greys out when
        -- buffs are off, like every other control on this page.
        -- Border Animation is intentionally NOT offered on the buff/debuff rows:
        -- these containers can hold many icons and animating each border is a
        -- per-frame FPS cost, so DF exposes border animations only on the
        -- low-count elements (Defensive / Missing Buff) and the Aura Designer.
        --
        -- ⚠ noShowToggle IS THE HOIST -- the Pet Frames / Resource Bar border row's
        -- move, verbatim. With it the built-in Show Border checkbox is not built and
        -- the row carries that tick instead; the show key is still read, so it still
        -- greys the other seventeen exactly as before.
        local function ApplyBuffBorder()
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            if DF.UpdateAllFrames then DF:UpdateAllFrames() end
            DF:LightweightUpdateAuraBorder("buff")
        end

        local function BuildBuffBorderGroup(tools2)
            GUI:CreateBorderControls(tools2.group, db, "buff", {
                parent        = tools2.parent,
                include       = { inset = true, offset = true, blendMode = true,
                                  gradient = true, shadow = true, alpha = true },
                sizeMin = 0, sizeMax = 8, sizeStep = 1,
                -- ☠ INVALIDATE, don't just update. Show Border is STRUCTURAL on the aura
                -- row: BuildAuraRowConfig emits `border = <spec> or nil`, so turning it
                -- off has to rebuild the container, and UpdateAllFrames alone only redoes
                -- layout. Without the invalidation the rows kept their old border until
                -- something else happened to bump the aura layout version — which is why
                -- it appeared to work on one frame and not the rest
                -- (Aphoex, 2026-08-12).
                fullUpdate    = function()
                    if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
                    if DF.UpdateAllFrames then DF:UpdateAllFrames() end
                end,
                lightUpdate   = function() DF:LightweightUpdateAuraBorder("buff") end,
                lightColors   = function() DF:LightweightUpdateAuraBorder("buff") end,
                refreshStates = tools2.refreshStates,
                -- The page gate goes in as the CONSUMER gate it has always been: this
                -- factory owns the whole group and writes disableOn onto each of the
                -- eighteen itself, so there is no group.disableChildrenOn here to skip
                -- index 1 -- and therefore no GatePaneFirstChild either.
                disableWhen   = function(d) return not d.showBuffs end,
                noShowToggle  = tools2.hoistToggle or nil,
            })
        end

        -- The Resource Bar border summary minus the colour source this include set
        -- does not have: thickness in pixels, the style word, and the alpha only when
        -- it is doing something.
        local function BuffBorderSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.buffBorderSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local style = d.buffBorderStyle
            parts[#parts + 1] = (style == "GRADIENT" and L["Gradient"])
                             or (style == "TEXTURE" and L["Texture"])
                             or L["Solid"]
            local c = d.buffBorderColor
            local a = type(c) == "table" and tonumber(c.a) or nil
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            return Join(parts)
        end

        if classicLayout then
            local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
            borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
            BuildBuffBorderGroup({
                group = borderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
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
            --
            -- ⚠ CLASSIC ONLY, now. In the popout layout there are no columns to balance:
            -- four full-width bands in reading order, and Border sits where it reads --
            -- after Position, still with the geometry.
            Add(borderGroup, nil, 1)
        else
            -- Seventeen: the eighteen CreateBorderControls builds for this include set,
            -- less the hoisted Show Border.
            local BUFF_BORDER_COUNT = 17

            -- What the suppressed Show Border checkbox ran, and never a page rebuild:
            -- that would retire every widget on the page including the row being
            -- clicked, and the row's write path calls row.Refresh() after this returns.
            local function OnBuffBorderToggle()
                ApplyBuffBorder()
                self:RefreshStates()
                tools.ReflowMounted()
            end

            local borderMount, borderContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffBorderGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local borderRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Border"],
                db       = tools.RowDB,
                toggle   = { key = "buffShowBorder" },
                summary  = BuffBorderSummary,
                count    = BUFF_BORDER_COUNT,
                onToggle = OnBuffBorderToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = borderMount,
            }))
            tools.ClaimKeys(borderRow, borderContent)
            tools.WireModifiedTick(borderRow)
            tools.WireFooter(borderRow, ApplyBuffBorder)
            tools.RegisterHoistedToggle(borderRow, L["Show Border"], "buffShowBorder", OnBuffBorderToggle)
            borderRow.disableOn = BuffsOffRow
        end

        -- ===== DURATION TEXT (a 280 box in column 2 in classic, the Text band's
        -- first row) =====
        -- "Duration Text", not "Duration": this box and Duration Bar are two renderings of
        -- the same value, and a bare "Duration" made the pair look like one had been
        -- separated from the other. The name says which one this is — and matches what the
        -- Aura Designer cards have always called it.
        local function ApplyBuffDurationText()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            DF:LightweightUpdateAuraDurationText("buff")
        end

        -- ☠ WHAT A DURATION FORMAT CHANGE COSTS, AND WHY IT IS NOT THE SAME IN BOTH
        -- LAYOUTS. Picking a format re-gates the two Hide Above controls (neither can
        -- compose with Percent), and classic has always paid for that with a whole
        -- page REBUILD. It keeps doing exactly that.
        --
        -- The pane must not. A rebuild retires every widget on the page including the
        -- row the user is clicking through, and the helper's own prologue closes every
        -- open panel on the way in -- so the dropdown they just used would slam shut
        -- under their hand. What the rebuild was buying is the hideOn/disableOn
        -- passes, and that is precisely what the pane's own refresh does.
        local function DurationFormatRefresh(tools2)
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            if tools2.popout then
                tools2.refreshStates()
            else
                GUI:RefreshCurrentPage()
            end
        end

        local function BuildBuffDurationGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the ROW carries this tick. Still built in classic, where
            -- it is the group's only on/off control.
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], db, "buffShowDuration", function()
                    tools2.refreshStates()
                    DF:UpdateAllFrames()
                end), 30)
            end
            -- The cooldown swipe (radial sweep) is the OTHER way time-remaining is
            -- shown, so it lives here with Duration Text rather than under Border.
            group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], db, "buffHideSwipe", nil), 30)
            local durFormat = GUI:CreateDurationFormatControls(parent, group, durationFormatOptions, db, "buffDurationFormat", function() DurationFormatRefresh(tools2) end)
            durFormat.disableOn = function(d) return not d.buffShowDuration end
            -- Shared TextStyle control block (font/scale/outline/shadow/colour/anchor/
            -- offsets/justify). The static colour greys out while Color-by-Time owns it.
            GUI:CreateTextControls(group, db, "buffDuration", {
                parent     = parent,
                include    = { color = true },
                colorLabel = L["Duration Color"],
                disableOn  = function(d) return not d.buffShowDuration end,
                colorDisableOn = function(d) return d.buffDurationColorByTime end,
                onChange   = function() DF:LightweightUpdateAuraDurationText("buff") end,
                onDrag     = function() DF:LightweightUpdateAuraDurationText("buff") end,
            })
            local durColor = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], db, "buffDurationColorByTime", function() tools2.refreshStates(); DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
            durColor.disableOn = function(d) return not d.buffShowDuration end
            AddColorsPageLink(group, parent)
            -- Hide Above can't compose with the Percent format (its threshold is seconds
            -- banded into a seconds-sampled formatter — see GetDurationFormatFields).
            local durHideAbove = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Above Threshold"], db, "buffDurationHideAboveEnabled", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
            durHideAbove.disableOn = function(d) return not d.buffShowDuration or DF:IsPercentDurationFormat(d.buffDurationFormat) end
            local durHideAboveSlider = group:AddWidget(GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, db, "buffDurationHideAboveThreshold", nil, function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
            durHideAboveSlider.disableOn = function(d) return not d.buffShowDuration or not d.buffDurationHideAboveEnabled or DF:IsPercentDurationFormat(d.buffDurationFormat) end
            local durHidePerm = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration on Permanent Auras"], db, "buffDurationHideOnPermanent", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
            durHidePerm.disableOn = function(d) return not d.buffShowDuration end
            -- Grey the whole group when Buffs are off (composes with the per-control
            -- buffShowDuration gates), matching Visibility/Position/Layout.
            group.disableChildrenOn = function(d) return not d.showBuffs end
        end

        -- Which of the four icon-sized formats the text is drawn in, in the dropdown's
        -- own words -- and the one option that takes the colour away from the swatch
        -- behind it.
        local function BuffDurationSummary(d)
            if not d then return "" end
            local parts = {}
            local fmt = durationFormatOptions[d.buffDurationFormat]
            if fmt then parts[#parts + 1] = fmt end
            if d.buffDurationColorByTime then parts[#parts + 1] = L["Color by Time Remaining"] end
            return Join(parts)
        end

        if classicLayout then
            local durationGroup = GUI:CreateSettingsGroup(self.child, 280)
            durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Text"]), 40)
            BuildBuffDurationGroup({
                group = durationGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(durationGroup, nil, 2)
        else
            -- Fifteen: the swipe tick, the format pick, the eight TextStyle controls,
            -- Color by Time and its cross-link, the Hide Above pair and the
            -- permanent-aura tick. The Show Duration tick is HOISTED onto the row.
            local BUFF_DURATION_COUNT = 15

            -- What the suppressed Show Duration checkbox ran, plus the repaint of every
            -- pane standing open.
            local function OnBuffDurationToggle()
                self:RefreshStates()
                DF:UpdateAllFrames()
                tools.ReflowMounted()
            end

            local durationMount, durationContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffDurationGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
                GatePaneFirstChild(group)
            end)
            local durationRow = textBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Duration Text"],
                db       = tools.RowDB,
                toggle   = { key = "buffShowDuration" },
                summary  = BuffDurationSummary,
                count    = BUFF_DURATION_COUNT,
                onToggle = OnBuffDurationToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = durationMount,
            }))
            tools.ClaimKeys(durationRow, durationContent)
            tools.WireModifiedTick(durationRow)
            tools.WireFooter(durationRow, ApplyBuffDurationText)
            tools.RegisterHoistedToggle(durationRow, L["Show Duration"], "buffShowDuration", OnBuffDurationToggle)
            durationRow.disableOn = BuffsOffRow
        end

        -- ===== STACK COUNT (a 280 box in column 2 in classic, the Text band's second
        -- row) =====
        -- The shared TextStyle control block (font/scale/outline/shadow/colour/anchor/
        -- offsets/justify) + the feature-specific extras. Directly under Duration, and in
        -- that order on every surface that has both: they are the two text elements on an
        -- icon and are tuned as a pair, so a user looking for one expects the other
        -- adjacent. Matches the Aura Designer cards.
        --
        -- ☠ NO TICK TO HOIST: the stack count is drawn by the game whenever an aura has
        -- one, and every control here styles it. There is no boolean that means "am I
        -- doing anything at all", so this is a WAY IN.
        local function ApplyBuffStackText() DF:LightweightUpdateAuraStackText("buff") end

        local function BuildBuffStackGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            GUI:CreateTextControls(group, db, "buffStack", {
                parent   = parent,
                include  = { color = true },
                onChange = function() DF:LightweightUpdateAuraStackText("buff") end,
                onDrag   = function() DF:LightweightUpdateAuraStackText("buff") end,
            })
            -- (No "Min Stacks to Show": a stacks formatter is FORBIDDEN on container rows — it
            -- throws on the secret combat stack count inside Blizzard's dirty pass and bricks
            -- the container (see the Features/Auras.lua tombstone). Native display is
            -- "counts > 1", so a custom minimum cannot be expressed; the setting is gone.)
            -- Grey the whole group when Buffs are off, matching Visibility/Position/Layout.
            group.disableChildrenOn = function(d) return not d.showBuffs end
        end

        -- Where the number sits and how big it is -- the two facts a styling row can
        -- state without opening. The anchor word comes out of the same nine-way table
        -- the TextStyle block's own dropdown offers.
        local function BuffStackSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.buffStackAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local scale = tonumber(d.buffStackScale)
            if scale and scale ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Scale"], scale) end
            return Join(parts)
        end

        if classicLayout then
            local stackCountGroup = GUI:CreateSettingsGroup(self.child, 280)
            stackCountGroup:AddWidget(GUI:CreateHeader(self.child, L["Stack Count"]), 40)
            BuildBuffStackGroup({
                group = stackCountGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(stackCountGroup, nil, 2)
        else
            -- Eight: the TextStyle block's font, scale, outline, shadow, colour, anchor
            -- and two offsets.
            local BUFF_STACK_COUNT = 8

            local stackMount, stackContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffStackGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local stackRow = textBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Stack Count"],
                db      = tools.RowDB,
                summary = BuffStackSummary,
                count   = BUFF_STACK_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = stackMount,
            }))
            tools.ClaimKeys(stackRow, stackContent)
            tools.WireModifiedTick(stackRow)
            tools.WireFooter(stackRow, ApplyBuffStackText)
            stackRow.disableOn = BuffsOffRow
        end

        -- (No Expiring Indicator group: the pre-12.1 expiring border/tint was driven by a
        -- ~3 Hz ticker reading remaining time, which is SECRET on 12.1. Removed 2026-07-25
        -- rather than left frosted. The 12.1-safe replacement is the DF.Expiration engine
        -- (Features/Expiration.lua) + GUI:CreateExpirationControls, currently adopted by the
        -- Aura Designer only -- rolling it out to these rows is a separate, unscheduled job.)

        -- ===== DURATION BAR (a 280 box in column 2 in classic, the headerless band's
        -- first row) =====
        local function BuildBuffDurationBarGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent, L["Shows a bar on each icon that drains with the aura's remaining time."], 250), 30)
            if not tools2.hoistToggle then
                local buffBarEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Duration Bar"], db, "buffDurationBarEnabled", function()
                    tools2.refreshStates()
                    BuffBarChanged()
                end), 30)
                buffBarEnable.keepEnabled = true
                buffBarEnable.disableOn = function(d) return not d.showBuffs end
            end
            group.disableChildrenOn = function(d) return not d.showBuffs or not d.buffDurationBarEnabled end
            -- Where the bar sits, then what it looks like. One box rather than two,
            -- matching Debuffs: every other optional element on the page is a single
            -- box, and splitting only this one made the bar read as more of a feature
            -- than its neighbours while taking up half of column 2.
            group:AddWidget(GUI:CreateDropdown(parent, L["Position"], durBarPositionOptions, db, "buffDurationBarPosition", BuffBarChanged), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Height"], 1, 12, 1, db, "buffDurationBarHeight", nil, BuffBarChanged, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Gap"], 0, 10, 1, db, "buffDurationBarGap", nil, BuffBarChanged, true), 55)
            group:AddWidget(GUI:CreateDropdown(parent, L["Color Mode"], DF:GetDurationBarColorModes(), db, "buffDurationBarColorMode", function()
                tools2.refreshStates()
                BuffBarChanged()
            end), 55)
            local buffBarTex = group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "buffDurationBarTexture", BuffBarChanged), 55)
            local buffBarCol = group:AddWidget(GUI:CreateColorPicker(parent, L["Bar Color"], db, "buffDurationBarColor", true, BuffBarChanged), 30)
            -- A curve mode brings its own ramp texture and forces white, so these two do
            -- nothing while it is selected - dim them rather than leave dead controls live.
            buffBarTex.disableOn = function(d) return DF:IsDurationBarCurveMode(d.buffDurationBarColorMode) end
            buffBarCol.disableOn = buffBarTex.disableOn
            group:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], db, "buffDurationBarBGColor", true, BuffBarChanged), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Reverse Fill"], db, "buffDurationBarReverseFill", BuffBarChanged), 30)
        end

        local function BuffDurationBarSummary(d)
            if not d then return "" end
            local parts = {}
            local pos = durBarPositionOptions[d.buffDurationBarPosition]
            if pos then parts[#parts + 1] = pos end
            local h = tonumber(d.buffDurationBarHeight)
            if h then parts[#parts + 1] = format("%dpx", math.floor(h)) end
            local modes = DF:GetDurationBarColorModes()
            local mode = modes and modes[d.buffDurationBarColorMode]
            if mode then parts[#parts + 1] = mode end
            return Join(parts)
        end

        if classicLayout then
            local durBarGroup = GUI:CreateSettingsGroup(self.child, 280)
            durBarGroup.hideOn = HideDurationBar
            -- "Duration Bar", not "Settings": the section that scoped that name is
            -- gone, and the page already has a Visibility box at the top.
            durBarGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Bar"]), 40)
            BuildBuffDurationBarGroup({
                group = durBarGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(durBarGroup, nil, 2)
        else
            -- Nine: the blurb, the position pick, height, gap, the colour mode, the
            -- texture and two colours, and Reverse Fill. The Enable tick is HOISTED.
            local BUFF_DURBAR_COUNT = 9

            local function OnBuffDurationBarToggle()
                self:RefreshStates()
                BuffBarChanged()
                tools.ReflowMounted()
            end

            local durBarMount, durBarContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffDurationBarGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local durBarRow = factoryBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Duration Bar"],
                db       = tools.RowDB,
                toggle   = { key = "buffDurationBarEnabled" },
                summary  = BuffDurationBarSummary,
                count    = BUFF_DURBAR_COUNT,
                onToggle = OnBuffDurationBarToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = durBarMount,
            }))
            -- The box's own hideOn becomes the ROW's, so the band collapses the slot
            -- rather than leaving a gap where a bar the client cannot draw would be.
            durBarRow.hideOn = HideDurationBar
            tools.ClaimKeys(durBarRow, durBarContent)
            tools.WireModifiedTick(durBarRow)
            tools.WireFooter(durBarRow, BuffBarChanged)
            tools.RegisterHoistedToggle(durBarRow, L["Enable Duration Bar"], "buffDurationBarEnabled", OnBuffDurationBarToggle)
            durBarRow.disableOn = BuffsOffRow
        end

        -- ===== PANDEMIC (a 280 box in column 2 in classic, the headerless band's
        -- second row) ===== (12.1 factory rows only, and only on PTR 8+ clients —
        -- CreatePandemicControls greys itself and says why on an older build.)
        --
        -- This is the ROW half of the feature the Aura Designer cards also carry. There is
        -- deliberately NO Expiration section on this page (the pre-12.1 expiring border was
        -- removed above and its 12.1 replacement is AD-only so far), so no collision check is
        -- passed — nothing here can clash with anything.
        --
        -- ⚠ noEnableToggle IS THE HOIST, the border toolkit's noShowToggle for the
        -- section that owns this one. The helper still reads the Enabled key for its
        -- own group gate, so the pane greys exactly as the box did.
        --
        -- ☠ AND THE ROW GREYS ON AN UNSUPPORTED CLIENT, NOT JUST WHEN BUFFS ARE OFF.
        -- The suppressed checkbox carried that gate itself (the silent-capability-skip
        -- rule: a user must not be able to switch on a feature that provably cannot
        -- render), and with the tick on the row the row is the only place left to say
        -- it. A greyed row still OPENS, so the "this build does not support it" note
        -- inside is still readable.
        local pandemicSupported = true
        if DF.Pandemic and DF.Pandemic.IsSupported then
            pandemicSupported = DF.Pandemic:IsSupported() and true or false
        end

        local function ApplyBuffPandemic()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
        end

        local function BuildBuffPandemicGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Highlights each icon once the aura can be refreshed without losing time."], 250), 30)
            GUI:CreatePandemicControls(group, db, {
                parent     = parent,
                prefix     = "buff",
                -- The row has to exist before any of this means anything; the helper folds this
                -- into both its group gate and its Enable toggle.
                masterGate = function(d) return not d.showBuffs end,
                fullUpdate = function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end,
                refreshStates = tools2.refreshStates,
                noEnableToggle = tools2.hoistToggle or nil,
            })
        end

        -- Which of the two reveals is drawn, in the Type dropdown's own words, and
        -- whether it pulses. Both silent while the feature is off -- the row's tick
        -- already says that.
        local function BuffPandemicSummary(d)
            if not d then return "" end
            if not d.buffPandemicEnabled then return "" end
            local parts = {}
            parts[#parts + 1] = (d.buffPandemicMode == "TINT") and L["Tint"] or L["Border"]
            if d.buffPandemicFlash then parts[#parts + 1] = L["Flash"] end
            return Join(parts)
        end

        if classicLayout then
            local pandemicGroup = GUI:CreateSettingsGroup(self.child, 280)
            pandemicGroup.hideOn = HideDurationBar   -- same gate: no factory row, no button to hang it on
            pandemicGroup:AddWidget(GUI:CreateHeader(self.child, L["Pandemic"]), 40)
            BuildBuffPandemicGroup({
                group = pandemicGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            -- ☠ COLUMN 2, and the note that used to argue it into column 1 is worth
            -- keeping: column 1 is layout PLUS the treatments applied to the whole icon
            -- (Border), column 2 is the elements drawn ON the icon (Appearance, Duration,
            -- Stack Count, Duration Bar). Applying that split literally gave 885 vs 2639,
            -- so Border and Pandemic were both moved left to reach 1781 vs 1743 -- and
            -- then column 1 gained the Buff Filters box, which is TALLER THAN ANY OTHER
            -- GROUP ON THE PAGE and, uniquely, a variable height, because it lists one row
            -- per built-in filter plus one per custom filter the user has made. That
            -- inverted the imbalance the crossing was correcting, so Pandemic went back
            -- and Border stayed: of the two, Border is the one "most tied to geometry --
            -- size, inset, offsets -- and reads naturally after Position".
            --
            -- ☠ The old counterweight arithmetic can no longer be recomputed here. With a
            -- variable-height group in column 1 there is no static answer; balance has to
            -- be judged on screen, with a realistic number of custom filters. None of this
            -- applies to the popout layout, which has no columns to balance.
            Add(pandemicGroup, nil, 2)
        else
            -- Twenty-six: the blurb, the eight pandemic controls the helper builds
            -- without its Enable tick, and the seventeen of the border toolkit it mounts
            -- for BORDER mode.
            local BUFF_PANDEMIC_COUNT = 26

            local function OnBuffPandemicToggle()
                self:RefreshStates()
                ApplyBuffPandemic()
                tools.ReflowMounted()
            end

            local pandemicMount, pandemicContent = tools.PopoutContent(function(group, holder, reflow)
                BuildBuffPandemicGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local pandemicRow = factoryBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Pandemic"],
                db       = tools.RowDB,
                toggle   = { key = "buffPandemicEnabled" },
                summary  = BuffPandemicSummary,
                count    = BUFF_PANDEMIC_COUNT,
                onToggle = OnBuffPandemicToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = pandemicMount,
            }))
            pandemicRow.hideOn = HideDurationBar
            tools.ClaimKeys(pandemicRow, pandemicContent)
            tools.WireModifiedTick(pandemicRow)
            tools.WireFooter(pandemicRow, ApplyBuffPandemic)
            tools.RegisterHoistedToggle(pandemicRow, L["Enable"], "buffPandemicEnabled", OnBuffPandemicToggle)
            pandemicRow.disableOn = function(d)
                return not pandemicSupported or BuffsOffRow(d)
            end
        end

        -- ===== THE FOUR BANDS, IN READING ORDER ===========================
        -- Added at the foot rather than in place: every band is full width, so there
        -- is no column flow left to unbalance and the order below is purely the order
        -- the page reads in.
        if not classicLayout then
            Add(contentBand, nil, "both")
            Add(iconBand, nil, "both")
            Add(textBand, nil, "both")
            Add(factoryBand, nil, "both")
        end

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

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: fourteen 280 boxes in two columns, in
        -- the columns and the order they have always had -- including the Important
        -- Debuffs crossing the column notes below argue for.
        --
        -- POPOUT turns THIRTEEN of them into feature rows in four bands, and the one
        -- single-setting group into a CONTROL ROW on the same plate:
        --
        --   "Content"   Visibility, Debuff Filters, Debuff Blacklist, Order & Limits
        --               and the Hide Duplicate Debuffs control row -- whether the bar
        --               exists, which debuffs reach it, which are struck back out
        --               again, how many of them and in what order.
        --   "Icon"      Appearance, Layout, Position, Border, Important Debuffs --
        --               the icon itself: how big, how they grid, where they sit, what
        --               rings them, and the one treatment applied to a SUBSET of them.
        --   "Text"      Duration Text, Stack Count, Dispel Text -- the three things
        --               WRITTEN on an icon.
        --   headerless  Duration Bar -- the 12.1-factory-only extra.
        --               ☠ NO HEADER, deliberately, and for the same reason the Buff
        --               Bar's fourth band has none: the row carries a hideOn, so a
        --               header would be a section title left standing over nothing on
        --               a client with no factory row. Debuffs have no Pandemic box to
        --               stand beside it (see the note at the foot of the page), so
        --               this band holds one row rather than two.
        --
        -- All three band headers are locale strings the page already ships.
        --
        -- Every converted group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates } and, where a toggle is hoisted,
        -- `hoistToggle`. The classic branch mounts the SAME builder into the box it
        -- always built, which is what makes "classic is unchanged" structural rather
        -- than a promise -- test_debuffbar_page_builders.lua pins the inventory of
        -- each one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery: eager holders, pane reflow, the key claim,
        -- the amber tick, the footer's Reset Group / Hold: Defaults, the hoisted-toggle
        -- search repair, the control-row registration and the band width. nil in
        -- classic, which is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        local contentBand, iconBand, textBand, factoryBand
        if tools then
            contentBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            contentBand:AddWidget(GUI:CreateHeader(self.child, L["Content"]), 40)
            iconBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            iconBand:AddWidget(GUI:CreateHeader(self.child, L["Icon"]), 40)
            textBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            textBand:AddWidget(GUI:CreateHeader(self.child, L["Text"]), 40)
            factoryBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
        end

        -- ===== THE PAGE'S VOCABULARY AND ITS GATES, AT PAGE SCOPE =========
        -- These tables used to sit inside the box that offered them. The rows print
        -- the chosen value as their SUMMARY, and a summary is written OUTSIDE the
        -- group's builder -- so the word has to come out of the same table the
        -- dropdown offers, or a row could say one thing while the control behind it
        -- says another. (The Buff Bar page hoisted its four for exactly this.)
        --
        -- ⚠ AND ABOVE EVERY BUILDER. A builder is a CLOSURE, and a closure captures
        -- the upvalue that exists when it is created -- so one declared above these
        -- lines would see nil rather than the table or the function.
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        local debuffSortOptions = {
            DEFAULT = L["Default (Slot Order)"],
            TIME = L["Time Remaining"],
            NAME = L["Alphabetical"],
            APPLIED = L["Order Applied"],
            _order = { "DEFAULT", "TIME", "NAME", "APPLIED" },
        }
        -- Icon-sized formats only (see the buff page's Duration Format note).
        local debuffDurationFormatOptions = { NUMBER = L["Standard"], SHORT = L["Units"],
            TIMER = L["Timer"], PERCENT = L["Percent"],
            _order = { "NUMBER", "SHORT", "TIMER", "PERCENT" } }
        local durBarPositionOptions = { BOTTOM = L["Bottom"], TOP = L["Top"] }
        -- Corner + nudge. Offsets are ADDED to a built-in overhang that pushes the badge
        -- out of whichever corner is picked, so 0/0 is already a sensible resting place.
        local badgePoints = { TOPRIGHT = L["Top Right"], TOPLEFT = L["Top Left"],
                              BOTTOMRIGHT = L["Bottom Right"], BOTTOMLEFT = L["Bottom Left"] }
        -- ★ TWO ENTRIES, NOT THREE. "Any Dispel Type" (ANY) was collapsed into
        -- "All Dispellable" (2026-08-22): the two were one query wearing two rows
        -- -- ANY was added when the PTR-5 DISPELLABLE token appeared, beside the
        -- old map-based ALL instead of underneath it, and once ALL moved onto the
        -- token (the secrecy fix in Features/Auras.lua) they were byte-identical.
        -- Every peer offers exactly two modes, as does DF's own dispel overlay.
        local dispelModeOptions = {
            PLAYER = L["Dispellable By Me"],
            ALL    = L["All Dispellable"],
            _order = { "PLAYER", "ALL" },
        }
        -- Blizzard's fixed categories, in the order the old page listed them.
        local DEBUFF_CATEGORIES = {
            { key = "debuffFilterBoss",         name = "Boss Debuffs",        desc = "Debuffs applied by dungeon and raid bosses." },
            { key = "debuffFilterRole",         name = "Role Debuffs",        desc = "Debuffs Blizzard flags as important for your role." },
            { key = "debuffFilterPriority",     name = "Priority Debuffs",    desc = "Debuffs Blizzard flags as high priority." },
            { key = "debuffFilterCrowdControl", name = "Crowd Control",       desc = "CC effects like stuns, roots, and incapacitates." },
            { key = "debuffFilterRaid",         name = "Raid Debuffs",        desc = "Other debuffs Blizzard flags for raid frames." },
            -- ⚠ Inserted BEFORE Dispellable, not appended: the entry below claims the
            -- dispel-mode dropdown is "just below", which is only true while it is the
            -- last row in this group.
            { key = "debuffFilterNonPlayer",    name = "Non-Player Debuffs",  desc = "Debuffs applied by enemies and the environment, never by a player or their pet. Use it to keep boss and trash effects while dropping player-cast clutter such as Sated or Forbearance." },
            -- ⚠ "just below" stays true on this page: the dispel-mode dropdown
            -- is the next widget in this same group.
            { key = "debuffFilterDispellable",  name = "Dispellable Debuffs", desc = "Debuffs that can be dispelled. Which dispels count is set just below." },
        }
        -- The blacklist's catalog, read once for the page: the row's COUNT and its
        -- summary are both arithmetic over it, and both are written outside the
        -- builder that lists it.
        local blacklistCatalog = (DF.AuraBlacklist and DF.AuraBlacklist.DebuffSpells) or {}

        -- Shared by both filter groups below: rebuild the native filter strings and
        -- re-drive the container rows. The blacklist rides the same refresh because
        -- the debuff row's excludeSpellIDs merge reacts to exactly this pair
        -- (Features/Auras.lua applyDebuffBlacklist).
        local function DebuffFilterChanged()
            if DF.RebuildDirectFilterStrings then DF:RebuildDirectFilterStrings() end
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
        end
        -- Every bar edit routes through the factory drive: the sig split decides
        -- Rebuild (enable/position/height/gap — layout reservation) vs in-place
        -- restyle (texture/colours) — same callback either way.
        local function DebuffBarChanged() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end
        -- ☠ THE TWO 12.1-ONLY GROUPS SHARE ONE PREDICATE, NAMED FOR WHAT IT ASKS.
        -- The Duration Bar (the native container drains the strip render-side; the
        -- legacy renderer has no bar) and the Dispel Text letters (the legacy
        -- renderer has no source for them) both vanish on a client where the factory
        -- does not own this row, and both used to spell the same test out for
        -- themselves -- one as a named HideDurationBar, one as an inline closure on
        -- the box. In the popout layout it is the ROW's hideOn on both, so the band
        -- collapses the slot instead of drawing an empty plate.
        local function NoFactoryRow(d) return not DF:FactoryOwnsDebuffRow(d) end

        -- ☠ THE PAGE GATE, ON THE ROWS. Show Debuffs greys every group it greyed in
        -- classic -- and ONLY those: the Debuff Filters box, the Debuff Blacklist box
        -- and the Hide Duplicate Debuffs box have never dimmed with it (you can pick
        -- what the bar would show before you switch it on), so their rows do not
        -- either.
        --
        -- ⚠ THE VISIBILITY ROW IS THE ONE EXCEPTION among the gated groups: it
        -- carries the gate's own tick, so greying it would leave no way to turn the
        -- bar back on.
        local function DebuffsOffRow(d) return not (d or db).showDebuffs end

        -- ☠ AND THE GROUP GATE SKIPS CHILD ONE, WHICH IN A PANE IS NOT A HEADER.
        -- DandersUI Sections' RefreshChildStates greys every child a
        -- disableChildrenOn covers EXCEPT index 1 -- correct for a page box, whose
        -- first child is always the header, and wrong for a popout pane, which has no
        -- header at all. The Pet Frames / Resource Bar answer, verbatim: spelled onto
        -- the widget itself, composed with whatever predicate it already carries, and
        -- applied at the MOUNT rather than inside the builder. Never runs in classic,
        -- where the box's own header is index 1.
        --
        -- Only the four panes whose first child is a GATED CONTROL need it. A pane
        -- opening on a label (Debuff Filters, Debuff Blacklist, Important Debuffs,
        -- Duration Bar) or on a control carrying the page gate itself (Visibility,
        -- Appearance, Layout, Position, Border) already greys.
        local function GatePaneFirstChild(group)
            local entry = group and group.groupChildren and group.groupChildren[1]
            local w = entry and entry.widget
            if not w then return end
            local prev = w.disableOn
            w.disableOn = function(d) return DebuffsOffRow(d) or (prev and prev(d)) or false end
        end

        -- The summary convention, once: at most four items, a fixed order,
        -- "\194\183" between them, WORDS localised and numbers raw, every read
        -- guarded because a profile mid-migration may be missing any of these keys.
        local function Join(parts) return table.concat(parts, " \194\183 ") end

        -- ===== VISIBILITY (a 280 box in column 1 in classic, the Content band's
        -- first row) =====
        -- Leads the page for the same reason it does on Buff Bar: Show Debuffs is the
        -- master switch everything else greys out under, so it must not be the fourth
        -- box down. Same name as its twin — the two pages are read as a pair, and a
        -- box holding the same two controls must not be called two different things.
        --
        -- ☠ ONE CONTROL BEHIND THE TICK, AND IT IS STILL A ROW RATHER THAN TWO
        -- CONTROL ROWS -- the Buff Bar's reasoning, verbatim: the row is where the
        -- page's master switch lives, and a control row carries a setting rather than
        -- a group, so it can offer neither the pair's Reset Group nor the tick that
        -- says the pair has been touched.
        local function BuildDebuffVisibilityGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the ROW carries this tick. Still built in classic,
            -- where it is the page's only on/off control.
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Debuffs"], db, "showDebuffs", function()
                    tools2.refreshStates()
                    -- See Show Buffs above: re-scan auras on visible frames so a static
                    -- debuff hides/shows immediately instead of waiting for the next aura event.
                    DF:RefreshAllVisibleFrames()
                end), 30)
            end
            local debuffMax = group:AddWidget(GUI:CreateSlider(parent, L["Max Debuffs"], 0, 8, 1, db, "debuffMax", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
            debuffMax.disableOn = function(d) return not d.showDebuffs end
        end

        -- What the whole page's gate costs when it moves, named once: the state pass,
        -- the aura re-scan the suppressed checkbox ran, and a repaint of every pane
        -- standing open -- ten of which grey with it.
        local function OnShowDebuffsToggle()
            self:RefreshStates()
            DF:RefreshAllVisibleFrames()
            if tools then tools.ReflowMounted() end
        end

        local function DebuffVisibilitySummary(d)
            if not d then return "" end
            local n = tonumber(d.debuffMax)
            if not n then return "" end
            return format("%s %d", L["Max Debuffs"], n)
        end

        if classicLayout then
            local visibilityGroup = GUI:CreateSettingsGroup(self.child, 280)
            visibilityGroup:AddWidget(GUI:CreateHeader(self.child, L["Visibility"]), 40)
            BuildDebuffVisibilityGroup({
                group = visibilityGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(visibilityGroup, nil, 1)
        else
            -- One: Max Debuffs. The Show Debuffs tick is HOISTED onto the row, so it
            -- is not one of them.
            local DEBUFF_VISIBILITY_COUNT = 1

            local visMount, visContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffVisibilityGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local visRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Visibility"],
                db       = tools.RowDB,
                toggle   = { key = "showDebuffs" },
                summary  = DebuffVisibilitySummary,
                count    = DEBUFF_VISIBILITY_COUNT,
                onToggle = OnShowDebuffsToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = visMount,
            }))
            tools.ClaimKeys(visRow, visContent)
            tools.WireModifiedTick(visRow)
            tools.WireFooter(visRow, function() DF:RefreshAllVisibleFrames() end)
            tools.RegisterHoistedToggle(visRow, L["Show Debuffs"], "showDebuffs", OnShowDebuffsToggle)
        end

        -- ===== DEBUFF FILTERS (a 280 box in column 1 in classic, the Content band's
        -- second row) =====
        -- WHICH debuffs reach this bar, moved here from the Aura Filters page.
        --
        -- ☠ These are NOT filters in the registry sense and there is no Manage
        -- Filters button, because there is nothing to manage: membership is
        -- Blizzard's and cannot be edited, added to or duplicated. That difference
        -- is the single most misleading thing about the old shared page, where these
        -- switches sat under the same tab strip as the editable buff library and
        -- looked identical to it. Here they are simply this bar's own controls.
        --
        -- ☠ NO TICK TO HOIST, and All Debuffs is NOT one. It does not switch the
        -- group off -- it switches the group's list off and shows MORE, which is the
        -- opposite of what a row's tick means. This is a WAY IN.
        local function BuildDebuffFilterGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent,
                "|cff888888" .. L["These categories are Blizzard's and cannot be edited."] .. "|r", 250), 35)

            local showAllCb = group:AddWidget(GUI:CreateCheckbox(parent, L["All Debuffs"], db, "directDebuffShowAll", function()
                tools2.refreshStates()
                DebuffFilterChanged()
            end), 30)
            showAllCb.tooltip = L["Show every debuff with no filtering."]

            -- The only real warning here, and it is about the COMBINATION: any single
            -- category obviously misses things, so saying that adds nothing. What is
            -- surprising is that switching on every category still is not All
            -- Debuffs, because Blizzard tagged some debuffs with none of them.
            --
            -- ☠ A CAUTION BANNER, CONDITIONAL — not a permanent grey caption. It was a
            -- banner on the old shared Filters page (catCaution, gated on this same
            -- switch) and became a static label when the debuff half moved here in
            -- cf70ac00; that page still carries a "see catCaution" comment pointing at
            -- the symbol the move deleted. Two things were lost with it:
            --   * it was CONDITIONAL. All Debuffs is on by default and is the correct
            --     setting, so a permanent caption warns the overwhelming majority of
            --     users about a state they are not in -- and the reader who IS in it
            --     gets no more emphasis than the reader who is not.
            --   * it was a CAUTION TONE. The completeness gap is Blizzard's and cannot
            --     be fixed from here: no combination of these tickboxes is complete.
            --     That is a genuine "this will silently miss things", not a footnote,
            --     and grey body text is the register this page uses for ordinary help.
            -- ⚠ The page-banner slot is deliberately NOT where this goes. That was
            -- tried and reverted on the old page: a warning about one switch, four
            -- inches from it, displaced the tab's own explanation while it showed.
            -- It belongs against the control that causes it.
            --
            -- ⚠ TEXT SET ONCE, AT CREATION, AND NEVER RE-SET. A banner whose
            -- SetText/SetHTML is driven from a refresh can feed the refreshContent
            -- loop that froze the GUI once before, so this one only ever gets hideOn.
            -- Do not add a refreshContent to it.
            --
            -- ☠ AND IT IS THE FIRST BANNER THE SWEEP HAS PUT INSIDE A PANE, which is
            -- why GUI:CreatePopoutPageTools now stamps `dfReflowPane` on the pane it
            -- mounts a group into. A banner measures its wrapped text a frame AFTER it
            -- is shown and then calls GUI:RelayoutHost -- and that walk had nothing to
            -- find above a pane, so the group re-laid out while the PANEL around it
            -- kept the height it was given at mount, clipping whatever the banner had
            -- just grown by. Unlike a measured label this cannot be opted out of with
            -- an explicit slot height (only opts.staticHeight silences it, and that
            -- would change what CLASSIC draws).
            local catCaution = GUI:CreateInfoBanner(parent, {
                tone = "caution",
                text = L["Only All Debuffs shows every debuff: all the categories combined still miss some debuffs."],
                minHeight = 30,
            })
            -- Shown only while All Debuffs is OFF — the state the warning is about, and
            -- turning that switch back on is what it tells you to do. A hidden group
            -- child collapses to nothing (LayoutChildren's entryVisible), so the rows
            -- below close up rather than leaving a hole where it would have been.
            catCaution.hideOn = function(d) return (d.directDebuffShowAll and true) or false end
            group:AddWidget(catCaution, catCaution.layoutHeight or 45)

            for _, cat in ipairs(DEBUFF_CATEGORIES) do
                local cb = group:AddWidget(GUI:CreateCheckbox(parent, L[cat.name], db, cat.key, function()
                    tools2.refreshStates()
                    DebuffFilterChanged()
                end), 30)
                -- Body only; the title comes from the checkbox label automatically.
                cb.tooltip = L[cat.desc]
                -- All Debuffs overrides the whole list.
                cb.disableOn = function(d) return d.directDebuffShowAll end
            end

            -- Which dispels count: a sub-option of the Dispellable Debuffs row above.
            -- ⚠ BOTH its gates live in this group now, so unlike its previous home it
            -- can never be greyed with nothing on the page able to lift it.
            --
            -- Self-heal, not just startup migration: the Core.lua one-shot rewrites
            -- every profile at login, but a profile or template IMPORTED mid-session
            -- can carry "ANY" back in, and this page is the only surface where the
            -- stale value would show (as a blank dropdown). Equality-gated and
            -- identical to the migration, so the two can never diverge.
            --
            -- ⚠ INSIDE THE BUILDER, not hoisted to page scope with the vocabulary. It
            -- has to run before the dropdown that would show the stale value is built,
            -- and a SECOND pane instance (pin one, open the row again) builds its own
            -- dropdown after an import could have put "ANY" back. It is equality-gated
            -- and idempotent, so running it once per instance costs nothing.
            if db.directDebuffDispellableMode == "ANY" then
                db.directDebuffDispellableMode = "ALL"
            end
            local dispelDD = group:AddWidget(GUI:CreateDropdown(parent, L["Dispellable Debuffs"], dispelModeOptions, db, "directDebuffDispellableMode", function()
                DebuffFilterChanged()
            end), 55)
            dispelDD.disableOn = function(d)
                return d.directDebuffShowAll or not d.debuffFilterDispellable
            end
            dispelDD.tooltip = L["Dispellable By Me: only debuffs you can dispel. All Dispellable: any debuff that can be dispelled."]
        end

        -- ☠ THE COUNT IS ARITHMETIC OVER THE CATEGORY TABLE, not a literal. The pane
        -- mounts one tick per category, so a number written down here would be wrong
        -- the moment Blizzard's list gains or loses one -- which it did as recently as
        -- Non-Player Debuffs.
        local function DebuffFilterCount()
            -- The caption, the All Debuffs switch, the caution banner and the
            -- dispel-mode dropdown, plus one row per category.
            return 4 + #DEBUFF_CATEGORIES
        end

        -- What the row says with the panel shut: how much of Blizzard's list is
        -- switched on, in the "3/7" shape the Buff Filters row uses, plus which
        -- dispels count while that category is one of them. All Debuffs overrides the
        -- list outright, so it is named instead of the fraction rather than beside it.
        local function DebuffFilterSummary(d)
            if not d then return "" end
            local parts = {}
            if d.directDebuffShowAll then
                parts[#parts + 1] = L["All Debuffs"]
            else
                local on = 0
                for _, cat in ipairs(DEBUFF_CATEGORIES) do
                    if d[cat.key] then on = on + 1 end
                end
                parts[#parts + 1] = format("%d/%d", on, #DEBUFF_CATEGORIES)
                local mode = d.debuffFilterDispellable and dispelModeOptions[d.directDebuffDispellableMode]
                if mode then parts[#parts + 1] = mode end
            end
            return Join(parts)
        end

        if classicLayout then
            local filterGroup = GUI:CreateSettingsGroup(self.child, 280)
            filterGroup:AddWidget(GUI:CreateHeader(self.child, L["Debuff Filters"]), 40)
            BuildDebuffFilterGroup({
                group = filterGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(filterGroup, nil, 1)
        else
            local filterMount, filterContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffFilterGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local filterRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Debuff Filters"],
                db      = tools.RowDB,
                summary = DebuffFilterSummary,
                count   = DebuffFilterCount(),
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = filterMount,
            }))
            tools.ClaimKeys(filterRow, filterContent)
            tools.WireModifiedTick(filterRow)
            -- ✓ A FOOTER HERE, unlike the Buff Bar's filter row, and the difference is
            -- checked rather than assumed: every key behind this group is a SCALAR --
            -- seven booleans, All Debuffs and one string -- so Reset Group's
            -- `db[key] = DeepCopy(default)` writes numbers and words rather than
            -- replacing a table the aura pipeline is holding. The buff row's refusal
            -- was about buffFilterSelection specifically; nothing of that shape is in
            -- here.
            tools.WireFooter(filterRow, DebuffFilterChanged)
        end

        -- ===== DEBUFF BLACKLIST (a 280 box in column 1 in classic, the Content
        -- band's third row) =====
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
        --
        -- ☠ A ROW, NOT A FULL-WIDTH BOX, AND THAT IS AN ARGUED CALL. This is a
        -- spell-list editor, and the sweep's standing verdict on those is "structural
        -- rebuild, leave it a box" -- the Color-by-Time list and the Filter Designer's
        -- own editors add and remove rows and rebuild the page under themselves. This
        -- one does neither: the CATALOG IS A CONSTANT (DF.AuraBlacklist.DebuffSpells,
        -- a shipped table with no add, no remove and no rename), so the widget list is
        -- fixed at build; every tick is a custom get/set over one entry in
        -- db.debuffBlacklist; and the group's only GUI call is the Reset button's
        -- state pass, which in a pane is the pane's own reflow. Nothing here rebuilds
        -- a page, so nothing here needs to stay a box.
        local function BuildDebuffBlacklistGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent,
                "|cff888888" .. L["Select a debuff to hide it from this bar. These are the only debuffs the game lets us hide."] .. "|r", 250), 45)

            local function BlacklistSet()
                db.debuffBlacklist = db.debuffBlacklist or {}
                return db.debuffBlacklist
            end

            for _, e in ipairs(blacklistCatalog) do
                local id = e.spellId
                -- Resolve the live client name so the row localises like the rest
                -- of the UI; the catalog's English display is the fallback.
                local name = e.display
                if C_Spell and C_Spell.GetSpellName then
                    local ok, v = pcall(C_Spell.GetSpellName, id)
                    if ok and type(v) == "string" and v ~= "" then name = v end
                end
                -- Direct binding, no negation on either side: ticked == blacklisted.
                group:AddWidget(GUI:CreateCheckbox(parent, name, nil, nil, DebuffFilterChanged,
                    function() return BlacklistSet()[id] and true or false end,
                    function(v)
                        local s = BlacklistSet()
                        s[id] = v or nil
                    end), 30)
            end

            -- Restore the shipped set. Mutated IN PLACE for the same reason the
            -- selection tables are: the aura pipeline holds a reference to this
            -- table and a fresh one would strand it.
            local resetBtn = group:AddWidget(GUI:CreateButton(parent, L["Reset"], 140, 22, function()
                local defaults = (db == DF.db.raid) and DF.RaidDefaults or DF.PartyDefaults
                local def = defaults and defaults.debuffBlacklist
                local s = BlacklistSet()
                for id in pairs(s) do s[id] = nil end
                if type(def) == "table" then
                    for id, on in pairs(def) do s[id] = on or nil end
                end
                tools2.refreshStates()
                DebuffFilterChanged()
            end), 30)
            resetBtn.tooltip = L["Debuff Blacklist"]
        end

        -- ☠ ARITHMETIC OVER THE CATALOG, not a literal: the shipped list has grown
        -- twice already (Ride Along, Challenger's Burden) and a written-down number
        -- would be wrong the next time it does.
        local function DebuffBlacklistCount()
            -- The caption, one tick per catalog entry, and Reset.
            return 2 + #blacklistCatalog
        end

        -- How much of the catalog is struck out, in the same fraction shape the two
        -- filter rows use. No word for it: "hidden" and "blacklisted" are both new
        -- locale strings for something the number already says beside a row called
        -- Debuff Blacklist.
        local function DebuffBlacklistSummary(d)
            if not d then return "" end
            local set = d.debuffBlacklist or {}
            local on = 0
            for _, e in ipairs(blacklistCatalog) do
                if set[e.spellId] then on = on + 1 end
            end
            return format("%d/%d", on, #blacklistCatalog)
        end

        -- ⚠ THE WHOLE SITE IS GUARDED ON THE CATALOG, in both layouts. An empty
        -- shipped list means there is nothing to blacklist, and the box has always
        -- been skipped outright rather than drawn empty; the row is skipped for the
        -- same reason, so the band closes over the slot.
        if #blacklistCatalog > 0 then
            if classicLayout then
                local blGroup = GUI:CreateSettingsGroup(self.child, 280)
                blGroup:AddWidget(GUI:CreateHeader(self.child, L["Debuff Blacklist"]), 40)
                BuildDebuffBlacklistGroup({
                    group = blGroup,
                    parent = self.child,
                    refreshStates = function() self:RefreshStates() end,
                })
                -- ⚠ Column 1, with the filters, not column 2. It is a CONTENT
                -- decision -- which debuffs reach the bar -- and column 2 on this
                -- page is styling. It also helps the balance, since column 2 carries
                -- Duration Text, Stack Count, Dispel Text and Duration Bar; but the
                -- reason is that it belongs beside the categories it narrows.
                Add(blGroup, nil, 1)
            else
                local blMount, blContent = tools.PopoutContent(function(group, holder, reflow)
                    BuildDebuffBlacklistGroup({
                        group = group, parent = holder,
                        refreshStates = reflow,
                        popout = true,
                    })
                end)
                local blacklistRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                    label   = L["Debuff Blacklist"],
                    db      = tools.RowDB,
                    summary = DebuffBlacklistSummary,
                    count   = DebuffBlacklistCount(),
                    window  = DF.GUIFrame,
                    clipTo  = self,
                    build   = blMount,
                }))
                -- ⚠ THE STORED SET IS NAMED, because the walk cannot see it. Every
                -- tick here is a CUSTOM get/set checkbox -- no db binding at all -- so
                -- what it registers with search is a synthetic per-entry key and the
                -- real setting, `debuffBlacklist`, is bound to nothing the walk can
                -- find. Named through `extra`, the amber tick asks about the table the
                -- user is actually editing.
                tools.ClaimKeys(blacklistRow, blContent, { "debuffBlacklist" })
                tools.WireModifiedTick(blacklistRow)
                -- ☠ NO FOOTER ON THIS ROW, AND IT IS A REFUSAL RATHER THAN AN
                -- OMISSION -- for a reason of its own, not the Buff Filters one.
                -- THIS GROUP ALREADY SHIPS A RESET, inside the pane, and the two do
                -- not do the same thing: the button above mutates the stored set IN
                -- PLACE (see the note on it), while Reset Group writes
                -- `db[key] = DeepCopy(default)` and REPLACES the table. Two buttons
                -- called Reset, four inches apart, one of which is the one the group
                -- was written to use -- the footer is the one that goes.
            end
        end

        -- ===== ORDER & LIMITS (a 280 box in column 1 in classic, the Content band's
        -- fourth row) =====
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
        --
        -- ☠ NO TICK TO HOIST. Nothing here is the group's on/off: Hide Long Debuffs
        -- gates two controls and nothing else, and Sort Order is a pick rather than a
        -- switch. This is a WAY IN.
        --
        -- ☠ "Dispellable Debuffs" (directDebuffDispellableMode) MOVED to the Debuff
        -- Filters group above, under the category row it belongs to. It lived here
        -- gated on `directDebuffShowAll or not debuffFilterDispellable` — and BOTH of
        -- those were set on another page, so with All Debuffs on by default it was
        -- permanently greyed and nothing on this page could lift it (Krathe,
        -- 2026-08-09).
        -- ⚠ Do not re-add it here. The storage is unchanged (same per-mode key); only
        -- the control moved, and its sync/reset ownership moved with it.

        -- Works in ALL-debuffs mode too (single maxDuration record) — only Keep
        -- Important needs the category filters (boolean flags can't be negated on
        -- the ALL record), so THAT toggle alone greys while All Debuffs is on.
        local function HideDebuffMaxDurControls(d)
            return not DF:FactoryOwnsDebuffRow(d)
        end

        local function BuildDebuffOrderGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- ⚠ The four sibling boxes on this page (Duration Text, Stack Count, Dispel
            -- Text, Duration Bar) all gate on showDebuffs; this one was simply missed, so
            -- it stayed live while the row it orders was switched off (Krathe, 2026-08-09).
            group.disableChildrenOn = function(d) return not d.showDebuffs end

            group:AddWidget(GUI:CreateDropdown(parent, L["Sort Order"], debuffSortOptions, db, "directDebuffSortOrder", function()
                DebuffFilterChanged()
                tools2.refreshStates()   -- My Auras First greys while Sort Order = Default
            end), 55)

            local dfSortMine = group:AddWidget(GUI:CreateCheckbox(parent, L["My Auras First"], db, "directDebuffSortMineFirst", DebuffFilterChanged), 30)
            dfSortMine.hideOn = function(d) return not DF:FactoryOwnsDebuffRow(d) end
            dfSortMine.disableOn = function(d) return not DF:SortOrderSupportsMineFirst(d.directDebuffSortOrder) end
            dfSortMine.tooltip = L["Sort your own auras before other players'. Unavailable on Default (which already shows yours first) and on Order Applied (which keeps one fixed order)."]
            local dfSortRev = group:AddWidget(GUI:CreateCheckbox(parent, L["Reverse Order"], db, "directDebuffSortReverse", DebuffFilterChanged), 30)
            dfSortRev.hideOn = function(d) return not DF:FactoryOwnsDebuffRow(d) end
            dfSortRev.tooltip = L["Reverse the sort direction."]

            local dfMaxDur = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Long Debuffs"], db, "debuffMaxDurationEnabled", function()
                DebuffFilterChanged()
                tools2.refreshStates()
            end), 30)
            dfMaxDur.hideOn = HideDebuffMaxDurControls
            dfMaxDur.tooltip = L["Hide debuffs whose total duration is longer than the threshold. Debuffs with no duration (permanent auras) are also hidden while this is on."]
            local dfMaxDurSlider = group:AddWidget(GUI:CreateSlider(parent, L["Hide Longer Than (minutes)"], 1, 30, 1, db, "debuffMaxDurationMinutes", nil, DebuffFilterChanged), 55)
            dfMaxDurSlider.hideOn = HideDebuffMaxDurControls
            dfMaxDurSlider.disableOn = function(d) return not d.debuffMaxDurationEnabled end

            local dfKeepImportant = group:AddWidget(GUI:CreateCheckbox(parent, L["Keep important debuffs"], db, "debuffMaxDurationKeepImportant", DebuffFilterChanged), 30)
            dfKeepImportant.hideOn = HideDebuffMaxDurControls
            dfKeepImportant.disableOn = function(d)
                return d.directDebuffShowAll or not d.debuffMaxDurationEnabled
            end
            dfKeepImportant.tooltip = L["Boss, Role, and Priority debuffs stay visible even when their duration is over the threshold."]
        end

        -- What sorting is doing, in the dropdown's own words, plus the one refinement
        -- that reverses everything it just said.
        local function DebuffOrderSummary(d)
            if not d then return "" end
            local parts = {}
            local sort = debuffSortOptions[d.directDebuffSortOrder]
            if sort then parts[#parts + 1] = sort end
            if d.directDebuffSortReverse then parts[#parts + 1] = L["Reverse Order"] end
            return Join(parts)
        end

        if classicLayout then
            local debuffOrderGroup = GUI:CreateSettingsGroup(self.child, 280)
            debuffOrderGroup:AddWidget(GUI:CreateHeader(self.child, L["Order & Limits"]), GUI.RowHeight.sectionHeader)
            BuildDebuffOrderGroup({
                group = debuffOrderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(debuffOrderGroup, nil, 1)
        else
            -- Six: the sort pick, its two refinements, the long-debuff pair and the
            -- keep-important tick.
            local DEBUFF_ORDER_COUNT = 6

            local orderMount, orderContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffOrderGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local orderRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Order & Limits"],
                db      = tools.RowDB,
                summary = DebuffOrderSummary,
                count   = DEBUFF_ORDER_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = orderMount,
            }))
            tools.ClaimKeys(orderRow, orderContent)
            tools.WireModifiedTick(orderRow)
            tools.WireFooter(orderRow, DebuffFilterChanged)
            orderRow.disableOn = DebuffsOffRow
        end

        -- ===== DEDUPLICATION (a 280 box in column 1 in classic, a CONTROL ROW in the
        -- Content band here) =====
        -- Same section, same position as the Buffs page: its own box at the top
        -- of column 1, ahead of the styling. The two pages' dedupe toggles must be
        -- findable in the same place.
        --
        -- ⚠ ONE SETTING IS A CONTROL ROW -- not a pane, which would be a click that
        -- buys one tick, and not a 280 box either, which is the one shape a column of
        -- full-width plates cannot absorb.
        --
        -- ⚠ AND THE ROW IS NAMED FOR THE SETTING, NOT FOR THE BOX -- the Buff Bar's
        -- rule, and for its reason: of "Deduplication" and "Hide Duplicate Debuffs",
        -- the one that survives standing alone on a plate is the sentence, not the
        -- jargon, and naming it that keeps the search result identical in both
        -- layouts because it is the caption the classic checkbox registers.
        --
        -- This was inlined because the only refresh helper used to be declared with
        -- the Order & Limits box FURTHER DOWN the function, so naming it here would
        -- have been a nil global — legal Lua, parses clean, silently dead checkbox.
        -- DebuffFilterChanged is page-scope now, above every group that needs it, so
        -- the hazard is gone and this simply calls it.
        local DEDUP_TIP = L["Hides debuffs that an Aura Designer group is already showing, so they don't appear twice."]

        if classicLayout then
            local dedupGroup = GUI:CreateSettingsGroup(self.child, 280)
            dedupGroup:AddWidget(GUI:CreateHeader(self.child, L["Deduplication"]), 40)
            local dfDedup = GUI:CreateCheckbox(self.child, L["Hide Duplicate Debuffs"], db, "debuffDeduplicateDesigner", DebuffFilterChanged)
            dfDedup.tooltip = DEDUP_TIP
            dedupGroup:AddWidget(dfDedup, 30)
            Add(dedupGroup, nil, 1)
        else
            local dedupRow = contentBand:AddWidget(GUI:CreateControlRow(self.child, {
                label     = L["Hide Duplicate Debuffs"],
                kind      = "checkbox",
                -- The FUNCTION form: the table is re-resolved on each read, so a mode
                -- switch is followed rather than frozen at whichever table this build
                -- captured.
                db        = tools.RowDB,
                key       = "debuffDeduplicateDesigner",
                onChanged = DebuffFilterChanged,
                tooltip   = DEDUP_TIP,
            }))
            -- No slot height: the factory owns it (fixedRowHeight + preferredHeight
            -- are the popout row's own slot), which is what makes a control row and a
            -- feature row share one rhythm in a band.
            tools.RegisterControlRow(dedupRow, "checkbox", "debuffDeduplicateDesigner", false, DebuffFilterChanged)
        end

        -- ===== APPEARANCE (a 280 box in column 2 in classic, the Icon band's first
        -- row) ===== -- mirrors Buffs; see the note there.
        local function ApplyDebuffPosition() DF:LightweightUpdateAuraPosition("debuff") end

        local function BuildDebuffAppearanceGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local debuffSize = group:AddWidget(GUI:CreateSlider(parent, L["Icon Size"], 10, 40, 1, db, "debuffSize", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
            debuffSize.disableOn = function(d) return not d.showDebuffs end
            local debuffScale = group:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.0, 0.05, db, "debuffScale", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
            debuffScale.disableOn = function(d) return not d.showDebuffs end
            local debuffAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0.0, 1.0, 0.05, db, "debuffAlpha", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
            debuffAlpha.disableOn = function(d) return not d.showDebuffs end
        end

        -- Pixels first, then the two multipliers, and each only while it is doing
        -- something -- a row reading "Scale 1.00 · Alpha 1.00" on every default
        -- profile is noise (the Resource Bar border row's rule).
        local function DebuffAppearanceSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.debuffSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local scale = tonumber(d.debuffScale)
            if scale and scale ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Scale"], scale) end
            local alpha = tonumber(d.debuffAlpha)
            if alpha and alpha < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], alpha) end
            return Join(parts)
        end

        if classicLayout then
            local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
            appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
            BuildDebuffAppearanceGroup({
                group = appearanceGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(appearanceGroup, nil, 2)
        else
            -- Three: size, scale, alpha.
            local DEBUFF_APPEARANCE_COUNT = 3

            local appearanceMount, appearanceContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffAppearanceGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local appearanceRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Appearance"],
                db      = tools.RowDB,
                summary = DebuffAppearanceSummary,
                count   = DEBUFF_APPEARANCE_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = appearanceMount,
            }))
            tools.ClaimKeys(appearanceRow, appearanceContent)
            tools.WireModifiedTick(appearanceRow)
            tools.WireFooter(appearanceRow, ApplyDebuffPosition)
            appearanceRow.disableOn = DebuffsOffRow
        end

        -- ===== LAYOUT (a 280 box in column 1 in classic, the Icon band's second
        -- row) =====
        local function BuildDebuffLayoutGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local debuffWrap = group:AddWidget(GUI:CreateSlider(parent, L["Icons Per Row"], 1, 8, 1, db, "debuffWrap", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
            -- ☠ THE SAME VERTICAL-GROWTH GUARD ITS TWO SIBLINGS CARRY. Both layout paths ignore
            -- the wrap count outright under vertical-primary growth (the row renders a single
            -- column), so without this the slider stayed live-looking and did nothing — in test
            -- mode AND in game. The buff row has carried the guard since the factory rows landed
            -- and the defensive row copies it; the debuff row never got one, which is what
            -- "Icons Per Row doesn't preview" is once Growth Direction is vertical. (Aphoex 7.2.)
            -- Kept term-for-term identical to the buff version rather than rephrased, so the
            -- three read as one rule.
            --
            -- ☠ AND THE GROWTH IT READS IS SET IN ANOTHER PANE. Position owns debuffGrowth;
            -- the growth control's own write ends in a page state pass, and ReflowMounted
            -- carries that to every pane standing open, so this slider re-gates from the
            -- next row down exactly as it did from the next box across.
            debuffWrap.disableOn = function(d)
                if not d.showDebuffs then return true end
                local g = d.debuffGrowth or ""
                -- Vertical-primary AND vertical-centred growth both render a single column.
                return DF:FactoryOwnsDebuffRow(d) and (g:sub(1, 2) == "UP" or g:sub(1, 4) == "DOWN"
                    or g == "CENTER_LEFT" or g == "CENTER_RIGHT")
            end
            local debuffPaddingX = group:AddWidget(GUI:CreateSlider(parent, L["Spacing X"], -5, 10, 1, db, "debuffPaddingX", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
            debuffPaddingX.disableOn = function(d) return not d.showDebuffs end
            local debuffPaddingY = group:AddWidget(GUI:CreateSlider(parent, L["Spacing Y"], -5, 10, 1, db, "debuffPaddingY", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
            debuffPaddingY.disableOn = function(d) return not d.showDebuffs end
        end

        local function DebuffLayoutSummary(d)
            if not d then return "" end
            local n = tonumber(d.debuffWrap)
            if not n then return "" end
            return format("%s %d", L["Icons Per Row"], n)
        end

        if classicLayout then
            local gridGroup = GUI:CreateSettingsGroup(self.child, 280)
            gridGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout"]), 40)
            BuildDebuffLayoutGroup({
                group = gridGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(gridGroup, nil, 1)
        else
            -- Three: icons per row and the two spacings.
            local DEBUFF_LAYOUT_COUNT = 3

            local layoutMount, layoutContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffLayoutGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local layoutRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Layout"],
                db      = tools.RowDB,
                summary = DebuffLayoutSummary,
                count   = DEBUFF_LAYOUT_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = layoutMount,
            }))
            tools.ClaimKeys(layoutRow, layoutContent)
            tools.WireModifiedTick(layoutRow)
            tools.WireFooter(layoutRow, ApplyDebuffPosition)
            layoutRow.disableOn = DebuffsOffRow
        end

        -- ===== POSITION (a 280 box in column 1 in classic, the Icon band's third
        -- row) =====
        local function BuildDebuffPositionGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local debuffAnchor = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "debuffAnchor", nil), 55)
            debuffAnchor.disableOn = function(d) return not d.showDebuffs end
            local debuffGrowth = group:AddWidget(GUI:CreateGrowthControl(parent, db, "debuffGrowth", nil), 155)
            debuffGrowth.disableOn = function(d) return not d.showDebuffs end
            local debuffOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, db, "debuffOffsetX", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
            debuffOffsetX.disableOn = function(d) return not d.showDebuffs end
            local debuffOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, db, "debuffOffsetY", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
            debuffOffsetY.disableOn = function(d) return not d.showDebuffs end
        end

        local function DebuffPositionSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.debuffAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local x, y = tonumber(d.debuffOffsetX) or 0, tonumber(d.debuffOffsetY) or 0
            if x ~= 0 or y ~= 0 then parts[#parts + 1] = format("%d, %d", x, y) end
            return Join(parts)
        end

        if classicLayout then
            local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
            positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
            BuildDebuffPositionGroup({
                group = positionGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(positionGroup, nil, 1)
        else
            -- Four: the anchor, the growth control (one widget, three stacked mini
            -- dropdowns inside it) and the two offsets.
            local DEBUFF_POSITION_COUNT = 4

            local positionMount, positionContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffPositionGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local positionRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Position"],
                db      = tools.RowDB,
                summary = DebuffPositionSummary,
                count   = DEBUFF_POSITION_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = positionMount,
            }))
            -- ⚠ debuffGrowth IS NAMED, because the walk cannot see it. The growth
            -- control is three hand-built mini dropdowns in a container -- it registers
            -- nothing with search and carries no dbKey -- so without this the row's tick
            -- and its Reset Group would both act as though the setting were on another
            -- page. (Its repaint after a reset is covered: the container's
            -- refreshContent re-decomposes the stored value, and RefreshChildStates runs
            -- it on every reflow.)
            tools.ClaimKeys(positionRow, positionContent, { "debuffGrowth" })
            tools.WireModifiedTick(positionRow)
            tools.WireFooter(positionRow, function() DF:UpdateAll() end)
            positionRow.disableOn = DebuffsOffRow
        end

        -- ☠ A SECOND, DRIFTED COPY OF THE INVALIDATION CONTRACT. This nilled the curve by
        -- hand and stopped there: it left DF.dispelColorMap cached and never bumped
        -- DF.dispelCurveGen, so the curve was rebuilt while every live carrier kept a
        -- reference to the OLD one and neither re-bind gate could fire -- colour changes
        -- from this control did not reach the frames. Call the one owner instead: it nils
        -- both caches, bumps the generation, and breaks the drive's fast-path latch.
        local function InvalidateAndUpdate()
            if DF.InvalidateDispelColorCurve then
                DF:InvalidateDispelColorCurve()
            else
                DF.debuffBorderCurve = nil
            end
            DF:UpdateAllFrames()
        end

        -- ===== BORDER (a 280 box in column 1 in classic, the Icon band's fourth
        -- row) =====
        -- Full border toolkit via the unified helper (Stage 5.5 Phase 2).  When
        -- "Color by Dispel Type" (below) is ON, the border is forced SOLID and
        -- recoloured per dispel type, so Style/Colour/Gradient here only take
        -- effect when it's OFF (Size/Inset always apply).  Border Animation is
        -- intentionally omitted (same FPS rationale as the buff row).
        --
        -- ⚠ noShowToggle IS THE HOIST -- the Buff Bar border row's move, verbatim.
        -- With it the built-in Show Border checkbox is not built and the row carries
        -- that tick instead; the show key is still read, so it still greys Color by
        -- Dispel Type exactly as before.
        local function ApplyDebuffBorder()
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            if DF.UpdateAllFrames then DF:UpdateAllFrames() end
            DF:LightweightUpdateAuraBorder("debuff")
        end

        local function BuildDebuffBorderGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            GUI:CreateBorderControls(group, db, "debuff", {
                parent        = parent,
                include       = { inset = true, offset = true, blendMode = true,
                                  gradient = true, shadow = true, alpha = true },
                sizeMin = 0, sizeMax = 8, sizeStep = 1,
                -- Structural, exactly as on the buff row above — see the note there.
                fullUpdate    = function()
                    if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
                    if DF.UpdateAllFrames then DF:UpdateAllFrames() end
                end,
                lightUpdate   = function() DF:LightweightUpdateAuraBorder("debuff") end,
                lightColors   = function() DF:LightweightUpdateAuraBorder("debuff") end,
                refreshStates = tools2.refreshStates,
                -- The page gate goes in as the CONSUMER gate it has always been: this
                -- factory owns its own eighteen and writes disableOn onto each of them
                -- itself, so there is no group.disableChildrenOn here to skip index 1 --
                -- and therefore no GatePaneFirstChild either.
                disableWhen   = function(d) return not d.showDebuffs end,
                noShowToggle  = tools2.hoistToggle or nil,
            })
            -- These three are added to the group BY HAND, so the toolkit's disableWhen
            -- doesn't reach them — they carry the Debuffs-off grey themselves or the
            -- box would half-grey.
            local colorByType = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Dispel Type"], db, "debuffBorderColorByType", InvalidateAndUpdate), 30)
            colorByType.disableOn = function(d) return not d.showDebuffs or not d.debuffShowBorder end
            -- 12.1 rows: the native dispel ring's inset (+ inward / - outward halo; the
            -- ring geometry is ours even though Blizzard tints it). Live via restyle.
            local dispelInset = group:AddWidget(GUI:CreateSlider(parent, L["Dispel Border Inset"], -8, 8, 1, db, "debuffDispelBorderInset", nil, function() DF:LightweightUpdateAuraBorder("debuff") end, true), 55)
            dispelInset.disableOn = function(d) return not d.showDebuffs or not d.debuffBorderColorByType end
            dispelInset.hideOn = function(d) return not DF:FactoryOwnsDebuffRow(d) end
            dispelInset.tooltip = L["How far the dispel-type ring sits inside the icon edge. Negative values push it outward into a halo around the icon instead."]
            -- Colors-page link right under "Color by Dispel Type": the dispel-type palette
            -- lives on the account-wide Colors page (one shared set, also used by the Dispel
            -- Overlay). Co-located with its toggle so it's obvious where to edit the colours.
            local dispelColorsLink = GUI:CreateDispelColorsPageLink(parent, 260)
            group:AddWidget(dispelColorsLink, (dispelColorsLink.layoutHeight or 16) + 2)
        end

        -- The Buff Bar border summary minus nothing: same include set, same three
        -- facts -- thickness in pixels, the style word, and the alpha only when it is
        -- doing something.
        local function DebuffBorderSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.debuffBorderSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local style = d.debuffBorderStyle
            parts[#parts + 1] = (style == "GRADIENT" and L["Gradient"])
                             or (style == "TEXTURE" and L["Texture"])
                             or L["Solid"]
            local c = d.debuffBorderColor
            local a = type(c) == "table" and tonumber(c.a) or nil
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            return Join(parts)
        end

        if classicLayout then
            local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
            borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
            BuildDebuffBorderGroup({
                group = borderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            -- ☠ COLUMN 1 — same call as the Buffs page, same reasoning, see the note there.
            -- This page is even more lopsided (939 of layout against 3229 of styling). Border
            -- lands under Position, which is where its size/inset/offset controls belong anyway.
            --
            -- ⚠ CLASSIC ONLY, now. In the popout layout there are no columns to balance:
            -- four full-width bands in reading order, and Border sits where it reads --
            -- after Position, still with the geometry.
            Add(borderGroup, nil, 1)
        else
            -- Twenty: the eighteen CreateBorderControls builds for this include set
            -- less the hoisted Show Border, plus the three this group adds by hand.
            local DEBUFF_BORDER_COUNT = 20

            -- What the suppressed Show Border checkbox ran, and never a page rebuild:
            -- that would retire every widget on the page including the row being
            -- clicked, and the row's write path calls row.Refresh() after this returns.
            local function OnDebuffBorderToggle()
                ApplyDebuffBorder()
                self:RefreshStates()
                tools.ReflowMounted()
            end

            local borderMount, borderContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffBorderGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local borderRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Border"],
                db       = tools.RowDB,
                toggle   = { key = "debuffShowBorder" },
                summary  = DebuffBorderSummary,
                count    = DEBUFF_BORDER_COUNT,
                onToggle = OnDebuffBorderToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = borderMount,
            }))
            tools.ClaimKeys(borderRow, borderContent)
            tools.WireModifiedTick(borderRow)
            tools.WireFooter(borderRow, ApplyDebuffBorder)
            tools.RegisterHoistedToggle(borderRow, L["Show Border"], "debuffShowBorder", OnDebuffBorderToggle)
            borderRow.disableOn = DebuffsOffRow
        end

        -- ===== IMPORTANT DEBUFFS (a 280 box in column 2 in classic, the Icon band's
        -- fifth row) =====
        -- Boss/role and priority debuffs already render as their OWN aura groups, and
        -- those groups are declared first — so they already lead the row. Everything
        -- here styles them so they also LOOK different without moving to a separate
        -- placement. Every change is STRUCTURAL (region presence / group layout cell /
        -- the group's init closure), so each callback must invalidate rather than
        -- lightweight-reposition — same pair the Hide Duplicate Debuffs toggle uses.
        --
        -- ⚠ IT SITS LAST IN THE ICON BAND, after Border rather than after Appearance.
        -- The classic note below already calls it "the OTHER whole-icon treatment on
        -- this page"; with no columns left to balance, the two whole-icon treatments
        -- read as a pair at the foot of the band.
        --
        -- ☠ THE HEADER SWATCH IS CLASSIC-ONLY, and that is a LOSS rather than a
        -- decision the popout layout gets for free. The box's header carries a live
        -- preview of the corner marker (GUI:AttachHeaderSwatch), and a popout row has
        -- no header to hang it on -- the kit's PopoutRow has no preview slot, and
        -- inventing one for a single consumer is a kit feature, not a page's business.
        -- Mounting a header INSIDE the pane was the other option and is worse: every
        -- other pane on every converted page opens straight onto its first control,
        -- and this one would open onto a 40px repeat of the row's own name. The row's
        -- summary carries the two facts the swatch showed in words instead (the size
        -- step and which corner the marker sits in), and the marker's own colour
        -- pickers are three rows into the pane. Raised for the sweep's owner rather
        -- than solved here.
        local UpdateImportantSwatch   -- assigned below in classic, once the header exists
        local function ImportantChanged()
            if DF.RebuildDirectFilterStrings then DF:RebuildDirectFilterStrings() end
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            -- The marker's own colour pickers change nothing structural on this page,
            -- so nothing else would repaint the swatch.
            if UpdateImportantSwatch then UpdateImportantSwatch() end
        end
        local function ImportantOff(d) return not d.showDebuffs or not d.debuffImportantHighlight end

        local function BuildImportantDebuffsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent,
                L["Makes boss, role and priority debuffs stand out in the normal debuff row."], 250), 30)

            -- Suppressed when the ROW carries this tick. Still built in classic, where
            -- it is the group's only on/off control.
            if not tools2.hoistToggle then
                local impOn = group:AddWidget(GUI:CreateCheckbox(parent, L["Highlight Important Debuffs"],
                    db, "debuffImportantHighlight", ImportantChanged), 30)
                impOn.disableOn = function(d) return not d.showDebuffs end
                impOn.tooltip = L["Boss, role and priority debuffs already sort to the front of the row. This also makes them larger and marks them, so they read at a glance without needing their own placement."]
            end

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
            local impScale = group:AddWidget(GUI:CreateSlider(parent, L["Size Step"], 1.0, 2.0, 0.05,
                db, "debuffImportantScale", ImportantChanged), 55)
            impScale.disableOn = ImportantOff
            impScale.tooltip = L["How much larger an important debuff renders. 1.00 keeps it the same size as the rest of the row."]

            local impBadge = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Corner Marker"],
                db, "debuffImportantBadge", ImportantChanged), 30)
            impBadge.disableOn = ImportantOff
            impBadge.tooltip = L["A small marker on the corner of the icon. It survives being shrunk better than a colour change, and it does not compete with the dispel border."]

            local impBadgeSize = group:AddWidget(GUI:CreateSlider(parent, L["Marker Size"], 6, 20, 1,
                db, "debuffImportantBadgeSize", ImportantChanged), 55)
            impBadgeSize.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

            -- hasAlpha=false, and NO lightweight path: a colour change here rebuilds the
            -- group (the tint is baked at initializeFrame), so there is nothing cheaper to
            -- run on drag. Signature is (parent, label, db, key, hasAlpha, cb, lightCb, useLight).
            local impBadgePt = group:AddWidget(GUI:CreateDropdown(parent, L["Marker Corner"],
                badgePoints, db, "debuffImportantBadgePoint", ImportantChanged), 55)
            impBadgePt.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

            local impBadgeX = group:AddWidget(GUI:CreateSlider(parent, L["Marker Offset X"], -20, 20, 1,
                db, "debuffImportantBadgeX", ImportantChanged), 55)
            impBadgeX.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

            local impBadgeY = group:AddWidget(GUI:CreateSlider(parent, L["Marker Offset Y"], -20, 20, 1,
                db, "debuffImportantBadgeY", ImportantChanged), 55)
            impBadgeY.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

            local impBadgeCol = group:AddWidget(GUI:CreateColorPicker(parent, L["Marker Color"],
                db, "debuffImportantBadgeColor", false, ImportantChanged, nil, false), 35)
            impBadgeCol.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end

            local impMarkCol = group:AddWidget(GUI:CreateColorPicker(parent, L["Marker Symbol Color"],
                db, "debuffImportantMarkColor", false, ImportantChanged, nil, false), 35)
            impMarkCol.disableOn = function(d) return ImportantOff(d) or not d.debuffImportantBadge end
        end

        -- Silent while the feature is off -- the row's tick already says that. On:
        -- how much bigger, and where the marker sits, in the corner dropdown's own
        -- words. The size step is skipped at 1.00, which is "no larger".
        local function ImportantDebuffsSummary(d)
            if not d then return "" end
            if not d.debuffImportantHighlight then return "" end
            local parts = {}
            local step = tonumber(d.debuffImportantScale)
            if step and step ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Size Step"], step) end
            if d.debuffImportantBadge then
                local corner = badgePoints[d.debuffImportantBadgePoint]
                if corner then parts[#parts + 1] = corner end
            end
            return Join(parts)
        end

        if classicLayout then
            local impGroup = GUI:CreateSettingsGroup(self.child, 280)
            -- Header carries a live preview of the corner marker itself (asked for in the
            -- field: the section names a feature whose art you otherwise cannot see without
            -- pulling a mob). Greys out — like the icon sections' previews — whenever the
            -- marker is not actually rendering: debuffs off, highlight off, or marker off.
            local impHeader = GUI:CreateHeader(self.child, L["Important Debuffs"])
            impGroup:AddWidget(impHeader, 40)
            -- 13px: the marker art is a filled disc, so it reads heavier than the padded
            -- icon atlases the section previews use — matched to the header text rather
            -- than to the other swatches' 16.
            local impSwatch = GUI:AttachHeaderSwatch(impHeader, 13, 2)
            UpdateImportantSwatch = function(d)
                if not impSwatch then return end
                d = d or DF.db[GUI.SelectedMode]
                if not d then return end
                impSwatch:SetSwatch({
                    { texture = "Interface\\AddOns\\DandersFrames\\Media\\DF_AlertBadge",
                      color = d.debuffImportantBadgeColor },
                    { texture = "Interface\\AddOns\\DandersFrames\\Media\\DF_AlertMark",
                      color = d.debuffImportantMarkColor },
                }, not d.showDebuffs or not d.debuffImportantHighlight or d.debuffImportantBadge == false)
            end
            -- RefreshChildStates calls refreshContent(db) on every shown child, so the
            -- swatch follows a mode switch / profile load without its own event.
            impHeader.refreshContent = function(_, d) UpdateImportantSwatch(d) end
            UpdateImportantSwatch(db)
            BuildImportantDebuffsGroup({
                group = impGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            -- ⚠ Crossed to column 2. It sat in column 1 as this page's counterweight to the
            -- styling boxes on the right (same reasoning as the buff page's Border note) --
            -- but column 1 has since gained Debuff Filters, Debuff Blacklist and Order &
            -- Limits, so the imbalance it was correcting now runs the other way. Important
            -- Debuffs is a mark drawn ON the icon, so column 2 is also where this page's
            -- own doctrine puts it: the crossing was the exception, and it is no longer
            -- needed to buy anything.
            Add(impGroup, nil, 2)
        else
            -- Nine: the blurb, the size step, the marker tick, its size, corner, two
            -- offsets and two colours. The Highlight tick is HOISTED onto the row.
            local DEBUFF_IMPORTANT_COUNT = 9

            -- What the suppressed Highlight checkbox ran, plus the two passes the row's
            -- tick owes the pane behind it. ⚠ THE STATE PASS IS NEW: ImportantChanged
            -- alone never re-ran one, so in classic the eight sub-controls kept their
            -- previous grey until something else refreshed the page. The row's tick
            -- cannot leave the pane it just gated in that state, and the fix is
            -- popout-only -- classic's checkbox is untouched.
            local function OnImportantToggle()
                self:RefreshStates()
                ImportantChanged()
                tools.ReflowMounted()
            end

            local impMount, impContent = tools.PopoutContent(function(group, holder, reflow)
                BuildImportantDebuffsGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local importantRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Important Debuffs"],
                db       = tools.RowDB,
                toggle   = { key = "debuffImportantHighlight" },
                summary  = ImportantDebuffsSummary,
                count    = DEBUFF_IMPORTANT_COUNT,
                onToggle = OnImportantToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = impMount,
            }))
            tools.ClaimKeys(importantRow, impContent)
            tools.WireModifiedTick(importantRow)
            tools.WireFooter(importantRow, ImportantChanged)
            tools.RegisterHoistedToggle(importantRow, L["Highlight Important Debuffs"], "debuffImportantHighlight", OnImportantToggle)
            importantRow.disableOn = DebuffsOffRow
        end

        -- ===== DURATION TEXT (a 280 box in column 2 in classic, the Text band's
        -- first row) ===== — "Duration Text" for the same reason as Buffs.
        local function ApplyDebuffDurationText()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            DF:LightweightUpdateAuraDurationText("debuff")
        end

        -- ☠ WHAT A DURATION FORMAT CHANGE COSTS, AND WHY IT IS NOT THE SAME IN BOTH
        -- LAYOUTS. Picking a format re-gates the two Hide Above controls (neither can
        -- compose with Percent), and classic has always paid for that with a whole
        -- page REBUILD. It keeps doing exactly that.
        --
        -- The pane must not. A rebuild retires every widget on the page including the
        -- row the user is clicking through, and the helper's own prologue closes every
        -- open panel on the way in -- so the dropdown they just used would slam shut
        -- under their hand. What the rebuild was buying is the hideOn/disableOn
        -- passes, and that is precisely what the pane's own refresh does.
        local function DurationFormatRefresh(tools2)
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            if tools2.popout then
                tools2.refreshStates()
            else
                GUI:RefreshCurrentPage()
            end
        end

        local function BuildDebuffDurationGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the ROW carries this tick. Still built in classic, where
            -- it is the group's only on/off control.
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], db, "debuffShowDuration", function()
                    tools2.refreshStates()
                    DF:UpdateAllFrames()
                end), 30)
            end
            -- Cooldown swipe (radial time-remaining) lives with Duration Text, not Border.
            group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], db, "debuffHideSwipe", nil), 30)
            local durFormat = GUI:CreateDurationFormatControls(parent, group, debuffDurationFormatOptions, db, "debuffDurationFormat", function() DurationFormatRefresh(tools2) end)
            durFormat.disableOn = function(d) return not d.debuffShowDuration end
            local durFont = group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], db, "debuffDurationFont", nil), 55)
            durFont.disableOn = function(d) return not d.debuffShowDuration end
            local durScale = group:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.0, 0.05, db, "debuffDurationScale", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
            durScale.disableOn = function(d) return not d.debuffShowDuration end
            local durOutline = group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], db, "debuffDurationOutline", function() DF:LightweightUpdateAuraDurationText("debuff") end), 55)
            durOutline.disableOn = function(d) return not d.debuffShowDuration end
            local durShadow = group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], db, "debuffDurationOutline", function() DF:LightweightUpdateAuraDurationText("debuff") end), 30)
            durShadow.disableOn = function(d) return not d.debuffShowDuration end
            local durAnchor = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "debuffDurationAnchor", function() DF:LightweightUpdateAuraDurationText("debuff") end), 55)
            durAnchor.disableOn = function(d) return not d.debuffShowDuration end
            local durX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, db, "debuffDurationX", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
            durX.disableOn = function(d) return not d.debuffShowDuration end
            local durY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, db, "debuffDurationY", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
            durY.disableOn = function(d) return not d.debuffShowDuration end
            local durColorPick = group:AddWidget(GUI:CreateColorPicker(parent, L["Duration Color"], db, "debuffDurationColor", false, function() DF:LightweightUpdateAuraDurationText("debuff") end, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 30)
            durColorPick.disableOn = function(d) return not d.debuffShowDuration or d.debuffDurationColorByTime end
            local durColor = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], db, "debuffDurationColorByTime", function() tools2.refreshStates(); DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
            durColor.disableOn = function(d) return not d.debuffShowDuration end
            AddColorsPageLink(group, parent)
            -- Hide Above can't compose with the Percent format (see the buff page).
            local durHideAbove = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Above Threshold"], db, "debuffDurationHideAboveEnabled", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
            durHideAbove.disableOn = function(d) return not d.debuffShowDuration or DF:IsPercentDurationFormat(d.debuffDurationFormat) end
            local durHideAboveSlider = group:AddWidget(GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, db, "debuffDurationHideAboveThreshold", nil, function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 55)
            durHideAboveSlider.disableOn = function(d) return not d.debuffShowDuration or not d.debuffDurationHideAboveEnabled or DF:IsPercentDurationFormat(d.debuffDurationFormat) end
            local durHidePerm = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration on Permanent Auras"], db, "debuffDurationHideOnPermanent", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end), 30)
            durHidePerm.disableOn = function(d) return not d.debuffShowDuration end
            -- Grey the whole group when Debuffs are off (composes with the per-control
            -- debuffShowDuration gates), matching Visibility/Position/Layout.
            group.disableChildrenOn = function(d) return not d.showDebuffs end
        end

        -- Which of the four icon-sized formats the text is drawn in, in the dropdown's
        -- own words -- and the one option that takes the colour away from the swatch
        -- behind it.
        local function DebuffDurationSummary(d)
            if not d then return "" end
            local parts = {}
            local fmt = debuffDurationFormatOptions[d.debuffDurationFormat]
            if fmt then parts[#parts + 1] = fmt end
            if d.debuffDurationColorByTime then parts[#parts + 1] = L["Color by Time Remaining"] end
            return Join(parts)
        end

        if classicLayout then
            local durationGroup = GUI:CreateSettingsGroup(self.child, 280)
            durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Text"]), 40)
            BuildDebuffDurationGroup({
                group = durationGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(durationGroup, nil, 2)
        else
            -- Fifteen: the swipe tick, the format pick, the eight text-style controls,
            -- Color by Time and its cross-link, the Hide Above pair and the
            -- permanent-aura tick. The Show Duration tick is HOISTED onto the row.
            local DEBUFF_DURATION_COUNT = 15

            -- What the suppressed Show Duration checkbox ran, plus the repaint of every
            -- pane standing open.
            local function OnDebuffDurationToggle()
                self:RefreshStates()
                DF:UpdateAllFrames()
                tools.ReflowMounted()
            end

            local durationMount, durationContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffDurationGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
                GatePaneFirstChild(group)
            end)
            local durationRow = textBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Duration Text"],
                db       = tools.RowDB,
                toggle   = { key = "debuffShowDuration" },
                summary  = DebuffDurationSummary,
                count    = DEBUFF_DURATION_COUNT,
                onToggle = OnDebuffDurationToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = durationMount,
            }))
            tools.ClaimKeys(durationRow, durationContent)
            tools.WireModifiedTick(durationRow)
            tools.WireFooter(durationRow, ApplyDebuffDurationText)
            tools.RegisterHoistedToggle(durationRow, L["Show Duration"], "debuffShowDuration", OnDebuffDurationToggle)
            durationRow.disableOn = DebuffsOffRow
        end

        -- ===== STACK COUNT (a 280 box in column 2 in classic, the Text band's second
        -- row) ===== — directly under Duration, and in that order on every surface
        -- that has both: they are the two text elements on an icon and are tuned as a
        -- pair, so a user looking for one expects the other adjacent. Matches Buffs and
        -- the Aura Designer cards.
        --
        -- ☠ NO TICK TO HOIST: the stack count is drawn by the game whenever an aura has
        -- one, and every control here styles it. There is no boolean that means "am I
        -- doing anything at all", so this is a WAY IN.
        local function ApplyDebuffStackText() DF:LightweightUpdateAuraStackText("debuff") end

        local function BuildDebuffStackGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], db, "debuffStackFont", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.0, 0.05, db, "debuffStackScale", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
            group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], db, "debuffStackOutline", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
            group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], db, "debuffStackOutline", function() DF:LightweightUpdateAuraStackText("debuff") end), 30)
            group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "debuffStackAnchor", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, db, "debuffStackX", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, db, "debuffStackY", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
            group:AddWidget(GUI:CreateColorPicker(parent, L["Color"], db, "debuffStackColor", false, function() DF:LightweightUpdateAuraStackText("debuff") end, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 30)
            -- (No "Min Stacks to Show" — see the Buffs page for why it cannot exist on 12.1.)
            -- Grey the whole group when Debuffs are off, matching Visibility/Position/Layout.
            group.disableChildrenOn = function(d) return not d.showDebuffs end
        end

        -- Where the number sits and how big it is -- the two facts a styling row can
        -- state without opening. The anchor word comes out of the same nine-way table
        -- this group's own dropdown offers.
        local function DebuffStackSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.debuffStackAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local scale = tonumber(d.debuffStackScale)
            if scale and scale ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Scale"], scale) end
            return Join(parts)
        end

        if classicLayout then
            local stackCountGroup = GUI:CreateSettingsGroup(self.child, 280)
            stackCountGroup:AddWidget(GUI:CreateHeader(self.child, L["Stack Count"]), 40)
            BuildDebuffStackGroup({
                group = stackCountGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(stackCountGroup, nil, 2)
        else
            -- Eight: font, scale, outline, shadow, anchor, two offsets and the colour.
            local DEBUFF_STACK_COUNT = 8

            local stackMount, stackContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffStackGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local stackRow = textBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Stack Count"],
                db      = tools.RowDB,
                summary = DebuffStackSummary,
                count   = DEBUFF_STACK_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = stackMount,
            }))
            tools.ClaimKeys(stackRow, stackContent)
            tools.WireModifiedTick(stackRow)
            tools.WireFooter(stackRow, ApplyDebuffStackText)
            stackRow.disableOn = DebuffsOffRow
        end

        -- ===== DISPEL TEXT (a 280 box in column 2 in classic, the Text band's third
        -- row) ===== — the dispel-type letters ("Ma", "Po", …), engine-written per
        -- aura (12.1 factory rows only; the legacy renderer has no source for them).
        -- ★ 2026-07-31: no longer requires Colorblind Mode. The bind passes
        -- customDispelTextMap, which takes Blizzard's direct SetText path instead of
        -- the CVar-gated one (DF:GetGameDispelTextMap, Frames/Border.lua) — so the
        -- old caution note and the CVar caveat in the tooltip are gone with it.
        -- Renamed from "Dispel Symbol" the same day: that read as the dispel ICON,
        -- which is a different native feature. DB keys stay debuffDispelSymbol*.
        --
        -- ⚠ IT STAYS IN THE TEXT BAND even though it shares the Duration Bar's factory
        -- gate. The band above it still has Duration Text and Stack Count in it on a
        -- client with no factory row, so its header is never left standing over
        -- nothing -- which is the only thing that argued the Duration Bar into a
        -- headerless band of its own.
        local function ApplyDispelText()
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            if DF.UpdateAllFrames then DF:UpdateAllFrames() end
        end

        local function BuildDebuffDispelTextGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the ROW carries this tick. Still built in classic, where
            -- it is the group's only on/off control.
            if not tools2.hoistToggle then
                local symbolEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Dispel Text"], db, "debuffDispelSymbolEnabled", function()
                    tools2.refreshStates()
                    -- Region presence is structural (create-once) — full re-drive rebuilds the row.
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                end), 30)
                symbolEnable.tooltip = L["Shows a short letter code on each debuff for its dispel type — Ma for Magic, Po for Poison, and so on. Uses the game's own wording for your language."]
                symbolEnable.keepEnabled = true
                symbolEnable.disableOn = function(d) return not d.showDebuffs end
            end
            GUI:CreateTextControls(group, db, "debuffDispelSymbol", {
                parent    = parent,
                include   = { color = true },
                disableOn = function(d) return not d.debuffDispelSymbolEnabled end,
                onChange  = function() DF:InvalidateAuraLayout() end,
                onDrag    = function() DF:InvalidateAuraLayout() end,
            })
            group.disableChildrenOn = function(d) return not d.showDebuffs end
        end

        -- The same two facts the Stack Count row states, off this block's own keys:
        -- where the letters sit and how big they are.
        local function DebuffDispelSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.debuffDispelSymbolAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local scale = tonumber(d.debuffDispelSymbolScale)
            if scale and scale ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Scale"], scale) end
            return Join(parts)
        end

        if classicLayout then
            local symbolGroup = GUI:CreateSettingsGroup(self.child, 280)
            symbolGroup:AddWidget(GUI:CreateHeader(self.child, L["Dispel Text"]), 40)
            BuildDebuffDispelTextGroup({
                group = symbolGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            symbolGroup.hideOn = NoFactoryRow
            -- ☠ Its hideOn makes this the one box on the page that can vanish, so it belongs in
            -- the SHORTER column: here it takes the page from 1972/1753 to 1972/2196 rather than
            -- lurching an already-long column by 443 every time the row backend changes.
            Add(symbolGroup, nil, 2)
        else
            -- Eight: the text-style block's font, scale, outline, shadow, colour,
            -- anchor and two offsets. The Show Dispel Text tick is HOISTED onto the row.
            local DEBUFF_DISPEL_COUNT = 8

            local function OnDispelTextToggle()
                self:RefreshStates()
                ApplyDispelText()
                tools.ReflowMounted()
            end

            local dispelMount, dispelContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffDispelTextGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
                GatePaneFirstChild(group)
            end)
            local dispelRow = textBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Dispel Text"],
                db       = tools.RowDB,
                toggle   = { key = "debuffDispelSymbolEnabled" },
                summary  = DebuffDispelSummary,
                count    = DEBUFF_DISPEL_COUNT,
                onToggle = OnDispelTextToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = dispelMount,
            }))
            -- The box's own hideOn becomes the ROW's, so the band collapses the slot
            -- rather than leaving a gap where letters the client cannot write would be.
            dispelRow.hideOn = NoFactoryRow
            tools.ClaimKeys(dispelRow, dispelContent)
            tools.WireModifiedTick(dispelRow)
            tools.WireFooter(dispelRow, ApplyDispelText)
            tools.RegisterHoistedToggle(dispelRow, L["Show Dispel Text"], "debuffDispelSymbolEnabled", OnDispelTextToggle)
            dispelRow.disableOn = DebuffsOffRow
        end

        -- ===== DURATION BAR (a 280 box in column 2 in classic, the headerless band's
        -- only row) ===== (12.1 factory rows only — mirrors the Buffs page's block;
        -- see there for the sig-split routing note)
        local function BuildDebuffDurationBarGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent, L["Shows a bar on each icon that drains with the aura's remaining time."], 250), 30)
            if not tools2.hoistToggle then
                local debuffBarEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Duration Bar"], db, "debuffDurationBarEnabled", function()
                    tools2.refreshStates()
                    DebuffBarChanged()
                end), 30)
                debuffBarEnable.keepEnabled = true
                debuffBarEnable.disableOn = function(d) return not d.showDebuffs end
            end
            group.disableChildrenOn = function(d) return not d.showDebuffs or not d.debuffDurationBarEnabled end
            -- Where the bar sits, then what it looks like. One box rather than two:
            -- every other optional element on this page (Stack Count, Dispel Text)
            -- is a single box, and splitting only this one into geometry + style
            -- made the bar read as more of a feature than its neighbours while
            -- taking up half of column 2.
            group:AddWidget(GUI:CreateDropdown(parent, L["Position"], durBarPositionOptions, db, "debuffDurationBarPosition", DebuffBarChanged), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Height"], 1, 12, 1, db, "debuffDurationBarHeight", nil, DebuffBarChanged, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Gap"], 0, 10, 1, db, "debuffDurationBarGap", nil, DebuffBarChanged, true), 55)
            group:AddWidget(GUI:CreateDropdown(parent, L["Color Mode"], DF:GetDurationBarColorModes(), db, "debuffDurationBarColorMode", function()
                tools2.refreshStates()
                DebuffBarChanged()
            end), 55)
            local debuffBarTex = group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "debuffDurationBarTexture", DebuffBarChanged), 55)
            local debuffBarCol = group:AddWidget(GUI:CreateColorPicker(parent, L["Bar Color"], db, "debuffDurationBarColor", true, DebuffBarChanged), 30)
            -- A curve mode brings its own ramp texture and forces white, so these two do
            -- nothing while it is selected - dim them rather than leave dead controls live.
            debuffBarTex.disableOn = function(d) return DF:IsDurationBarCurveMode(d.debuffDurationBarColorMode) end
            debuffBarCol.disableOn = debuffBarTex.disableOn
            group:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], db, "debuffDurationBarBGColor", true, DebuffBarChanged), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Reverse Fill"], db, "debuffDurationBarReverseFill", DebuffBarChanged), 30)
        end

        local function DebuffDurationBarSummary(d)
            if not d then return "" end
            local parts = {}
            local pos = durBarPositionOptions[d.debuffDurationBarPosition]
            if pos then parts[#parts + 1] = pos end
            local h = tonumber(d.debuffDurationBarHeight)
            if h then parts[#parts + 1] = format("%dpx", math.floor(h)) end
            local modes = DF:GetDurationBarColorModes()
            local mode = modes and modes[d.debuffDurationBarColorMode]
            if mode then parts[#parts + 1] = mode end
            return Join(parts)
        end

        if classicLayout then
            local durBarGroup = GUI:CreateSettingsGroup(self.child, 280)
            durBarGroup.hideOn = NoFactoryRow
            durBarGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Bar"]), 40)
            BuildDebuffDurationBarGroup({
                group = durBarGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(durBarGroup, nil, 2)
        else
            -- Nine: the blurb, the position pick, height, gap, the colour mode, the
            -- texture and two colours, and Reverse Fill. The Enable tick is HOISTED.
            local DEBUFF_DURBAR_COUNT = 9

            local function OnDebuffDurationBarToggle()
                self:RefreshStates()
                DebuffBarChanged()
                tools.ReflowMounted()
            end

            local durBarMount, durBarContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDebuffDurationBarGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local durBarRow = factoryBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Duration Bar"],
                db       = tools.RowDB,
                toggle   = { key = "debuffDurationBarEnabled" },
                summary  = DebuffDurationBarSummary,
                count    = DEBUFF_DURBAR_COUNT,
                onToggle = OnDebuffDurationBarToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = durBarMount,
            }))
            -- The box's own hideOn becomes the ROW's, so the band collapses the slot
            -- rather than leaving a gap where a bar the client cannot draw would be.
            durBarRow.hideOn = NoFactoryRow
            tools.ClaimKeys(durBarRow, durBarContent)
            tools.WireModifiedTick(durBarRow)
            tools.WireFooter(durBarRow, DebuffBarChanged)
            tools.RegisterHoistedToggle(durBarRow, L["Enable Duration Bar"], "debuffDurationBarEnabled", OnDebuffDurationBarToggle)
            durBarRow.disableOn = DebuffsOffRow
        end

        -- (No Pandemic box here, unlike Buffs. This row shows harmful auras on a FRIENDLY
        -- unit — cast on your party by something else — which you cannot refresh, so they
        -- have no refresh window and the cue could never light. Controls wired to an
        -- impossibility are worse than no controls. See BuildAuraRowConfig in
        -- Features/Auras.lua for the render-side gate that matches this.)

        -- ===== THE FOUR BANDS, IN READING ORDER ===========================
        -- Added at the foot rather than in place: every band is full width, so there
        -- is no column flow left to unbalance and the order below is purely the order
        -- the page reads in.
        if not classicLayout then
            Add(contentBand, nil, "both")
            Add(iconBand, nil, "both")
            Add(textBand, nil, "both")
            Add(factoryBand, nil, "both")
        end

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

        -- What the Settings group's two remaining ticks cost between them: the
        -- strip's own drive, and the buff row's, because Hide Raid Buffs from Buff
        -- Bar is a candidate filter on the OTHER row.
        local function ApplyMissingSettings()
            refreshMissing()
            DF:UpdateAllAuras()
        end

        local anchorOptions = {
            ["TOPLEFT"]= L["Top Left"], ["TOP"]= L["Top"], ["TOPRIGHT"]= L["Top Right"],
            ["LEFT"]= L["Left"], ["CENTER"]= L["Center"], ["RIGHT"]= L["Right"],
            ["BOTTOMLEFT"]= L["Bottom Left"], ["BOTTOM"]= L["Bottom"], ["BOTTOMRIGHT"]= L["Bottom Right"],
        }

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: five 280 boxes in two columns, in
        -- the columns and the order they have always had.
        --
        -- POPOUT turns all five into feature rows in two bands:
        --
        --   "Content"   Settings and Buffs to Check (Manual Mode) -- whether the
        --               icon exists at all, and which raid buffs it is watching.
        --   "Icon"      Appearance, Position, Border -- how big the icon is, where
        --               it sits and what rings it.
        --
        -- Both band headers are locale strings the page already ships, and neither
        -- can strand: the Content band's first row carries the page's own gate and
        -- is never hidden, and none of the Icon band's three can hide either.
        --
        -- Every converted group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates } and, where a toggle is hoisted,
        -- `hoistToggle`. The classic branch mounts the SAME builder into the box it
        -- always built -- test_missingbuffs_page_builders.lua pins the inventory of
        -- each one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery: eager holders, pane reflow, the key
        -- claim, the amber tick, the footer's Reset Group / Hold: Defaults, the
        -- hoisted-toggle search repair and the band width. nil in classic, which is
        -- what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        local contentBand, iconBand
        if tools then
            contentBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            contentBand:AddWidget(GUI:CreateHeader(self.child, L["Content"]), 40)
            iconBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            iconBand:AddWidget(GUI:CreateHeader(self.child, L["Icon"]), 40)
        end

        -- ☠ THE PAGE GATE, ON THE ROWS. Enable Missing Buff Icon greys every group
        -- it greyed in classic -- all four of the others, which is every box on the
        -- page bar the one carrying the tick itself.
        --
        -- ⚠ THE SETTINGS ROW IS THE EXCEPTION, for the Buff Bar's reason: it holds
        -- the gate's own tick, so greying it would leave no way to switch the icon
        -- back on.
        local function MissingOffRow(d) return not (d or db).missingBuffIconEnabled end

        -- ☠ AND THE GROUP GATE SKIPS CHILD ONE, WHICH IN A PANE IS NOT A HEADER.
        -- DandersUI Sections' RefreshChildStates greys every child a
        -- disableChildrenOn covers EXCEPT index 1 -- correct for a page box, whose
        -- first child is always the header, and wrong for a popout pane, which has
        -- no header at all. The Pet Frames / Resource Bar / Buff Bar answer,
        -- verbatim: composed with whatever predicate the widget already carries and
        -- applied at the MOUNT rather than inside the builder.
        --
        -- Only the three panes that OPEN ON A GATED CONTROL need it. Settings and
        -- Buffs to Check both open on a label, which has nothing to grey.
        local function GatePaneFirstChild(group)
            local entry = group and group.groupChildren and group.groupChildren[1]
            local w = entry and entry.widget
            if not w then return end
            local prev = w.disableOn
            w.disableOn = function(d) return MissingOffRow(d) or (prev and prev(d)) or false end
        end

        -- The summary convention, once: at most four items, a fixed order,
        -- "\194\183" between them, WORDS localised and numbers raw, every read
        -- guarded because a profile mid-migration may be missing any of these keys.
        local function Join(parts) return table.concat(parts, " \194\183 ") end

        -- ===== SETTINGS (a 280 box in column 1 in classic, the Content band's
        -- first row) =====
        -- ☠ THE ROW CARRIES THE PAGE'S MASTER SWITCH, which is why this is a row
        -- rather than three control rows: a control row carries a SETTING rather
        -- than a group, so it can offer neither the group's Reset Group nor the
        -- tick that says the group has been touched -- and the page gate would then
        -- belong to no row at all.
        local function BuildMissingSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent, L["Shows icon when party members are missing raid buffs."], 250), 30)
            -- 12.1 (factory path): the read-free widget works in combat + Mythic+ and
            -- shows EVERY tracked-and-missing buff (the legacy "first missing only"
            -- priority pick needed a cross-aura read). Legacy path keeps the caveat.
            local mbOwns = DF.FactoryOwnsMissingBuff and DF:FactoryOwnsMissingBuff(db)
            local mPlusWarn = GUI:CreateInfoBanner(parent, { tone = mbOwns and "info" or "caution" })
            mPlusWarn:SetText(mbOwns
                and L["Updates instantly, including in combat and Mythic+. Each tracked buff that is missing shows its own icon."]
                or L["Does NOT work in Mythic+ keystones. In combat, results may be slightly delayed."])
            group:AddWidget(mPlusWarn, 60)

            -- Suppressed when the ROW carries this tick. Still built in classic,
            -- where it is the page's only on/off control.
            if not tools2.hoistToggle then
                local missingBuffEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Missing Buff Icon"], db, "missingBuffIconEnabled", function()
                    tools2.refreshStates()
                    refreshMissing()
                end), 30)
                missingBuffEnable.keepEnabled = true
            end
            group.disableChildrenOn = HideMissingBuffOptions
            local mbAutoDetect = group:AddWidget(GUI:CreateCheckbox(parent, L["Auto-detect (your class's buff)"], db, "missingBuffClassDetection", function()
                -- ⚠ THIS ONE MOVES ANOTHER ROW. Auto-detect is the variant gate on
                -- Buffs to Check, so the state pass is what makes that row appear and
                -- disappear -- exactly as it made the box do it, and through the same
                -- page-level pass either way.
                tools2.refreshStates()
                refreshMissing()
            end), 30)
            mbAutoDetect.tooltip = L["Watches whichever raid buff your own class provides, and follows you when you change character. Turn it off to pick the buffs to watch by hand below."]
            local mbHideFromBar = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Raid Buffs from Buff Bar"], db, "missingBuffHideFromBar", function()
                -- Factory: the exclusion is a structural candidate-filter on the BUFF row —
                -- refreshMissing's InvalidateAuraLayout re-drives it (sig change -> Rebuild).
                refreshMissing()
                DF:UpdateAllAuras()
            end), 30)
            mbHideFromBar.tooltip = L["Stops the raid buffs tracked here from also taking up a slot in the normal buff row, so the missing-buff icon is the only place they appear."]
            -- (No Debug Mode checkbox: its trace narrated the legacy UnitHasBuff scan, which
            -- never runs on the read-free 12.1 widget -- presence is never known to Lua, so
            -- there is nothing to print. Removed 2026-07-25 as its own comment long proposed.)
        end

        -- The two ticks the row does not carry, in their own words. Silent while
        -- neither is on, which is the shipped profile.
        local function MissingSettingsSummary(d)
            if not d then return "" end
            local parts = {}
            if d.missingBuffClassDetection then parts[#parts + 1] = L["Auto-detect (your class's buff)"] end
            if d.missingBuffHideFromBar then parts[#parts + 1] = L["Hide Raid Buffs from Buff Bar"] end
            return Join(parts)
        end

        if classicLayout then
            local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
            settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
            BuildMissingSettingsGroup({
                group = settingsGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(settingsGroup, nil, 1)
        else
            -- Four: the blurb, the client-capability banner, Auto-detect and Hide
            -- Raid Buffs from Buff Bar. The Enable tick is HOISTED onto the row.
            local MISSING_SETTINGS_COUNT = 4

            -- What the suppressed Enable checkbox ran, plus a repaint of every pane
            -- standing open -- four of which grey with it. Never a page rebuild:
            -- that would retire the row being clicked through.
            local function OnMissingEnableToggle()
                self:RefreshStates()
                refreshMissing()
                tools.ReflowMounted()
            end

            local settingsMount, settingsContent = tools.PopoutContent(function(group, holder, reflow)
                BuildMissingSettingsGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local settingsRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Settings"],
                db       = tools.RowDB,
                toggle   = { key = "missingBuffIconEnabled" },
                summary  = MissingSettingsSummary,
                count    = MISSING_SETTINGS_COUNT,
                onToggle = OnMissingEnableToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = settingsMount,
            }))
            tools.ClaimKeys(settingsRow, settingsContent)
            tools.WireModifiedTick(settingsRow)
            tools.WireFooter(settingsRow, ApplyMissingSettings)
            tools.RegisterHoistedToggle(settingsRow, L["Enable Missing Buff Icon"], "missingBuffIconEnabled", OnMissingEnableToggle)
        end

        -- ===== BUFFS TO CHECK (MANUAL MODE) (a 280 box in column 1 in classic, the
        -- Content band's second row) =====
        -- ☠ A WAY IN, NOT A STRUCTURAL SKIP. This looks like a spell list and is
        -- not one: it is a FIXED, SHIPPED CATALOG of six raid buffs behind six
        -- boolean profile keys, with nothing to add and nothing to remove -- the
        -- Debuff Blacklist's verdict, for the same reason. Nothing here rebuilds
        -- the page, so the pane is clean.
        --
        -- ☠ AND THE ROW HIDES WITH THE BOX. The variant gate is auto-detect: with
        -- it on there is nothing to pick by hand, so the row collapses out of the
        -- band exactly as the box collapsed out of the column.
        local function BuildMissingBuffsToCheckGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent, L["When auto-detect is OFF, select which raid buffs to monitor manually."], 250), 35)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Arcane Intellect (Mage)"], db, "missingBuffCheckIntellect", function()
                refreshMissing()
            end), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Power Word: Fortitude (Priest)"], db, "missingBuffCheckStamina", function()
                refreshMissing()
            end), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Battle Shout (Warrior)"], db, "missingBuffCheckAttackPower", function()
                refreshMissing()
            end), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Mark of the Wild (Druid)"], db, "missingBuffCheckVersatility", function()
                refreshMissing()
            end), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Skyfury (Shaman)"], db, "missingBuffCheckSkyfury", function()
                refreshMissing()
            end), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Blessing of the Bronze (Evoker)"], db, "missingBuffCheckBronze", function()
                refreshMissing()
            end), 30)
            group.disableChildrenOn = HideMissingBuffOptions
        end

        -- ⚠ THE KEYS ARE NAMED ONCE, FOR THE SUMMARY ONLY. The six checkboxes stay
        -- spelled out above rather than looping this table: the census is of what
        -- the classic box built, and a loop would collapse six calls into one. The
        -- test asserts every key here appears in the builder, so the pair cannot
        -- drift apart silently.
        local MISSING_BUFF_KEYS = {
            "missingBuffCheckIntellect", "missingBuffCheckStamina",
            "missingBuffCheckAttackPower", "missingBuffCheckVersatility",
            "missingBuffCheckSkyfury", "missingBuffCheckBronze",
        }

        -- How much of the catalog is switched on, in the "3/6" shape the filter
        -- rows on the two bar pages use.
        local function MissingBuffsToCheckSummary(d)
            if not d then return "" end
            local on = 0
            for _, k in ipairs(MISSING_BUFF_KEYS) do
                if d[k] then on = on + 1 end
            end
            return format("%d/%d", on, #MISSING_BUFF_KEYS)
        end

        if classicLayout then
            local buffsGroup = GUI:CreateSettingsGroup(self.child, 280)
            buffsGroup:AddWidget(GUI:CreateHeader(self.child, L["Buffs to Check (Manual Mode)"]), 40)
            BuildMissingBuffsToCheckGroup({
                group = buffsGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            buffsGroup.hideOn = HideManualBuffVariant
            Add(buffsGroup, nil, 1)
        else
            -- Seven: the caption and the six raid buffs.
            local MISSING_BUFFS_COUNT = 7

            local buffsMount, buffsContent = tools.PopoutContent(function(group, holder, reflow)
                BuildMissingBuffsToCheckGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local buffsRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Buffs to Check (Manual Mode)"],
                db      = tools.RowDB,
                summary = MissingBuffsToCheckSummary,
                count   = MISSING_BUFFS_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = buffsMount,
            }))
            -- The box's own variant gate becomes the ROW's, so the band collapses
            -- the slot instead of drawing a plate for a list auto-detect has taken
            -- over.
            buffsRow.hideOn = HideManualBuffVariant
            tools.ClaimKeys(buffsRow, buffsContent)
            tools.WireModifiedTick(buffsRow)
            -- ⚠ A FOOTER IS SAFE HERE, and that is a decision about the KEYS rather
            -- than the shape. All six are plain booleans in the profile, so Reset
            -- Group writes VALUES -- there is no table for it to replace and nothing
            -- downstream holding a reference to one. (The Buff Bar's filter row
            -- refused a footer for exactly the opposite reason.)
            tools.WireFooter(buffsRow, refreshMissing)
            buffsRow.disableOn = MissingOffRow
        end

        -- ===== APPEARANCE (a 280 box in column 2 in classic, the Icon band's first
        -- row) =====
        local function BuildMissingAppearanceGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = HideMissingBuffOptions
            group:AddWidget(GUI:CreateSlider(parent, L["Icon Size"], 12, 48, 1, db, "missingBuffIconSize", function()
                refreshMissing()
            end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 3.0, 0.1, db, "missingBuffIconScale", function()
                refreshMissing()
            end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
            group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, "missingBuffIconFrameLevel", function()
                refreshMissing()
            end, function() DF:LightweightUpdateFrameLevel("missingBuff") end, true)), 55)
        end

        -- Pixels first, then the multiplier, and the multiplier only while it is
        -- doing something -- a row reading "Scale 1.00" on every default profile is
        -- noise (the Buff Bar's appearance rule). Frame Level is left out: it is a
        -- stacking-order fix, not a look.
        local function MissingAppearanceSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.missingBuffIconSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local scale = tonumber(d.missingBuffIconScale)
            if scale and scale ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Scale"], scale) end
            return Join(parts)
        end

        if classicLayout then
            local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
            appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
            BuildMissingAppearanceGroup({
                group = appearanceGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(appearanceGroup, nil, 2)
        else
            -- Three: size, scale and the frame level.
            local MISSING_APPEARANCE_COUNT = 3

            local appearanceMount, appearanceContent = tools.PopoutContent(function(group, holder, reflow)
                BuildMissingAppearanceGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local appearanceRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Appearance"],
                db      = tools.RowDB,
                summary = MissingAppearanceSummary,
                count   = MISSING_APPEARANCE_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = appearanceMount,
            }))
            tools.ClaimKeys(appearanceRow, appearanceContent)
            tools.WireModifiedTick(appearanceRow)
            tools.WireFooter(appearanceRow, refreshMissing)
            appearanceRow.disableOn = MissingOffRow
        end

        -- ===== POSITION (a 280 box in column 1 in classic, the Icon band's second
        -- row) =====
        local function BuildMissingPositionGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = HideMissingBuffOptions
            group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "missingBuffIconAnchor", function()
                refreshMissing()
            end), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, db, "missingBuffIconX", function()
                refreshMissing()
            end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, db, "missingBuffIconY", function()
                refreshMissing()
            end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        end

        local function MissingPositionSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.missingBuffIconAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local x, y = tonumber(d.missingBuffIconX) or 0, tonumber(d.missingBuffIconY) or 0
            if x ~= 0 or y ~= 0 then parts[#parts + 1] = format("%d, %d", x, y) end
            return Join(parts)
        end

        if classicLayout then
            local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
            positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
            BuildMissingPositionGroup({
                group = positionGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(positionGroup, nil, 1)
        else
            -- Three: the anchor and the two offsets.
            local MISSING_POSITION_COUNT = 3

            local positionMount, positionContent = tools.PopoutContent(function(group, holder, reflow)
                BuildMissingPositionGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local positionRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Position"],
                db      = tools.RowDB,
                summary = MissingPositionSummary,
                count   = MISSING_POSITION_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = positionMount,
            }))
            tools.ClaimKeys(positionRow, positionContent)
            tools.WireModifiedTick(positionRow)
            tools.WireFooter(positionRow, refreshMissing)
            positionRow.disableOn = MissingOffRow
        end

        -- ===== BORDER (a 280 box in column 2 in classic, the Icon band's third
        -- row) =====
        -- Stage 4.1: hand-rolled border block replaced by the unified helper.
        -- include set tailored for a "needs attention" alert: alpha / inset /
        -- offset / blendMode / gradient / shadow / animate (matches the
        -- Defensive Icon — Border Offset nudges the band relative to the icon).
        -- Class/Role colour offered too: the missing-buff icon sits on a unit
        -- frame, so its border can communicate WHOSE buff is missing at a glance.
        -- Skipped: colour-by-time / colour-by-type (no aura-state context here).
        --
        -- ⚠ noShowToggle IS THE HOIST -- the Pet Frames / Resource Bar / Buff Bar
        -- border row's move, verbatim. With it the built-in Show Border checkbox is
        -- not built and the row carries that tick instead; the show key is still
        -- read, so it still greys the other thirty-one exactly as before.
        local function BuildMissingBorderGroup(tools2)
            GUI:CreateBorderControls(tools2.group, db, "missingBuffIcon", {
                parent       = tools2.parent,
                include      = { alpha = true, inset = true, offset = true, blendMode = true,
                                 gradient = true, shadow = true, animate = true,
                                 classColor = true, roleColor = true },
                fullUpdate   = function() refreshMissing() end,
                lightUpdate  = function() DF:LightweightUpdateMissingBuff() end,
                lightColors  = function() DF:LightweightUpdateMissingBuffBorderColor() end,
                refreshStates = tools2.refreshStates,
                sizeMin = 0, sizeMax = 6, sizeStep = 1,  -- 0 = animation-only (no solid edge)
                noShowToggle = tools2.hoistToggle or nil,
            })
            -- No hideWhen: the group gate below is what handles the feature being
            -- off, and it GREYS like every other box on this page. (This call used to
            -- pass both, so the controls vanished before the grey could show.)
            tools2.group.disableChildrenOn = HideMissingBuffOptions
        end

        -- The Buff Bar's border summary, unchanged: thickness in pixels, the style
        -- word, and the alpha only when it is doing something.
        local function MissingBorderSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.missingBuffIconBorderSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local style = d.missingBuffIconBorderStyle
            parts[#parts + 1] = (style == "GRADIENT" and L["Gradient"])
                             or (style == "TEXTURE" and L["Texture"])
                             or L["Solid"]
            local c = d.missingBuffIconBorderColor
            local a = type(c) == "table" and tonumber(c.a) or nil
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            return Join(parts)
        end

        if classicLayout then
            local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
            borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
            BuildMissingBorderGroup({
                group = borderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(borderGroup, nil, 2)
        else
            -- Thirty-one: the thirty-two CreateBorderControls builds for this
            -- include set -- the widest one in the addon, animation and a colour
            -- source included -- less the hoisted Show Border.
            local MISSING_BORDER_COUNT = 31

            -- What the suppressed Show Border checkbox ran, and never a page
            -- rebuild: that would retire every widget on the page including the row
            -- being clicked through.
            local function OnMissingBorderToggle()
                self:RefreshStates()
                refreshMissing()
                tools.ReflowMounted()
            end

            local borderMount, borderContent = tools.PopoutContent(function(group, holder, reflow)
                BuildMissingBorderGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
                GatePaneFirstChild(group)
            end)
            local borderRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Border"],
                db       = tools.RowDB,
                toggle   = { key = "missingBuffIconShowBorder" },
                summary  = MissingBorderSummary,
                count    = MISSING_BORDER_COUNT,
                onToggle = OnMissingBorderToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = borderMount,
            }))
            tools.ClaimKeys(borderRow, borderContent)
            tools.WireModifiedTick(borderRow)
            tools.WireFooter(borderRow, refreshMissing)
            tools.RegisterHoistedToggle(borderRow, L["Show Border"], "missingBuffIconShowBorder", OnMissingBorderToggle)
            borderRow.disableOn = MissingOffRow
        end

        -- ===== THE TWO BANDS, IN READING ORDER ============================
        -- Added at the foot rather than in place: both bands are full width, so
        -- there is no column flow left to unbalance and the order below is purely
        -- the order the page reads in.
        if not classicLayout then
            Add(contentBand, nil, "both")
            Add(iconBand, nil, "both")
        end

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

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: nine 280 boxes in two columns, in
        -- the columns and the order they have always had.
        --
        -- POPOUT turns all nine into feature rows in four bands:
        --
        --   "Content"   Settings and Defensive Filters -- whether the icon exists
        --               at all, and which cooldowns reach it.
        --   "Icon"      Layout, Appearance, Position, Border -- how the icons
        --               arrange, how big they are, where they sit, what rings them.
        --   "Text"      Duration Text, Stack Count -- the two things WRITTEN on an
        --               icon, which have always been tuned as a pair.
        --   headerless  Duration Bar -- the one 12.1-factory-only extra.
        --               ☠ NO HEADER, deliberately: the row carries the factory
        --               gate, so a header would be a section title left standing
        --               over nothing on a client where the row is not drawn.
        --
        -- ⚠ STACK COUNT CAN HIDE TOO AND STILL SITS UNDER A HEADER. Duration Text
        -- stands under "Text" on a client with no factory row, so that header is
        -- never left over nothing -- the Debuff Bar's reasoning for Dispel Text,
        -- verbatim.
        --
        -- All three band headers are locale strings the page already ships.
        --
        -- Every converted group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates } and, where a toggle is hoisted,
        -- `hoistToggle`. The classic branch mounts the SAME builder into the box it
        -- always built -- test_defensiveicon_page_builders.lua pins the inventory
        -- of each one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery: eager holders, pane reflow, the key
        -- claim, the amber tick, the footer's Reset Group / Hold: Defaults, the
        -- hoisted-toggle search repair and the band width. nil in classic, which is
        -- what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        local contentBand, iconBand, textBand, factoryBand
        if tools then
            contentBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            contentBand:AddWidget(GUI:CreateHeader(self.child, L["Content"]), 40)
            iconBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            iconBand:AddWidget(GUI:CreateHeader(self.child, L["Icon"]), 40)
            textBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            textBand:AddWidget(GUI:CreateHeader(self.child, L["Text"]), 40)
            factoryBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
        end

        -- ===== THE PAGE'S VOCABULARY AND ITS GATES, AT PAGE SCOPE =========
        -- These tables used to sit inside the box that offered them. The rows print
        -- the chosen value as their SUMMARY, and a summary is written OUTSIDE the
        -- group's builder -- so the word has to come out of the same table the
        -- dropdown offers, or a row could say one thing while the control behind it
        -- says another.
        --
        -- ⚠ AND ABOVE EVERY BUILDER. A builder is a CLOSURE, and a closure captures
        -- the upvalue that exists when it is created -- so one declared above these
        -- lines would see nil rather than the table or the function.
        local anchorOptions = {
            CENTER= L["Center"], TOP= L["Top"], BOTTOM= L["Bottom"], LEFT= L["Left"], RIGHT= L["Right"],
            TOPLEFT= L["Top Left"], TOPRIGHT= L["Top Right"], BOTTOMLEFT= L["Bottom Left"], BOTTOMRIGHT= L["Bottom Right"],
        }
        -- Native rows only — the legacy fallback keeps its own fixed order.
        local defSortOptions = {
            DEFAULT = L["Default (Slot Order)"],
            TIME = L["Most Urgent"],
            EXTERNALS = L["Externals First"],
        }
        -- Duration Format (PTR-7 #5): previously hardcoded NUMBER; icon-sized
        -- formats only (see the buff page's Duration Format note). No Hide Above
        -- on this page, so no percent-grey needed.
        local defDurFormatOptions = { NUMBER = L["Standard"], SHORT = L["Units"],
            TIMER = L["Timer"], PERCENT = L["Percent"],
            _order = { "NUMBER", "SHORT", "TIMER", "PERCENT" } }
        local defBarPositionOptions = { BOTTOM = L["Bottom"], TOP = L["Top"] }

        local R = DF.FilterRegistry

        -- Dependent controls GREY OUT (disabled-in-place) when the feature is off.
        local function HideDefensiveIconOptions(d)
            return not d.defensiveIconEnabled
        end

        -- ☠ THE TWO 12.1-ONLY GROUPS SHARE ONE PREDICATE, NAMED FOR WHAT IT ASKS.
        -- Stack Count (the legacy renderer draws its own hardcoded count) and the
        -- Duration Bar (the native container drains the strip render-side) both
        -- vanish on a client where the factory does not own this row, and the Sort
        -- Order dropdown inside Layout asks the same question of itself. All three
        -- used to spell the test out separately. In the popout layout it is the
        -- ROW's hideOn on the two groups, so the band collapses the slot instead of
        -- drawing an empty plate.
        local function NoFactoryRow(d) return not DF:FactoryOwnsDefensiveRow(d) end

        -- What every group on this page costs when it is written to: the container
        -- drive. Named once so the rows' footers apply exactly what their controls
        -- apply.
        local function ApplyDefensive()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end
        -- The duration TEXT is structural on the aura row (a region that exists or
        -- does not), so its reset has to bump the layout version as well.
        local function ApplyDefensiveDurationText()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            ApplyDefensive()
        end
        local function DefBarChanged()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end

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

        -- ☠ THE PAGE GATE, ON THE ROWS. Enable Defensive Icon greys every group it
        -- greyed in classic -- which on this page is ALL of them, the filter list
        -- included. (That is where this page parts company with the two bar pages,
        -- whose filter box has never dimmed with the bar.)
        --
        -- ⚠ THE SETTINGS ROW IS THE ONE EXCEPTION: it carries the gate's own tick,
        -- so greying it would leave no way to switch the icon back on.
        local function DefensiveOffRow(d) return not (d or db).defensiveIconEnabled end

        -- ☠ AND THE GROUP GATE SKIPS CHILD ONE, WHICH IN A PANE IS NOT A HEADER.
        -- DandersUI Sections' RefreshChildStates greys every child a
        -- disableChildrenOn covers EXCEPT index 1 -- correct for a page box, whose
        -- first child is always the header, and wrong for a popout pane, which has
        -- no header at all. The Pet Frames / Resource Bar / Buff Bar answer,
        -- verbatim: composed with whatever predicate the widget already carries and
        -- applied at the MOUNT rather than inside the builder.
        --
        -- Only the panes that OPEN ON A GATED CONTROL need it. Settings, Layout,
        -- Defensive Filters and Duration Bar all open on a label, which has nothing
        -- to grey.
        local function GatePaneFirstChild(group)
            local entry = group and group.groupChildren and group.groupChildren[1]
            local w = entry and entry.widget
            if not w then return end
            local prev = w.disableOn
            w.disableOn = function(d) return DefensiveOffRow(d) or (prev and prev(d)) or false end
        end

        -- The summary convention, once: at most four items, a fixed order,
        -- "\194\183" between them, WORDS localised and numbers raw, every read
        -- guarded because a profile mid-migration may be missing any of these keys.
        local function Join(parts) return table.concat(parts, " \194\183 ") end

        -- ===== SETTINGS (a 280 box in column 1 in classic, the Content band's
        -- first row) =====
        -- ☠ THE ROW CARRIES THE PAGE'S MASTER SWITCH, which is why this is a row
        -- rather than a control row: a control row carries a SETTING rather than a
        -- group, so it could offer neither the pair's Reset Group nor the tick that
        -- says the pair has been touched -- and the page gate would then belong to
        -- no row at all.
        local function BuildDefensiveSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent, L["Shows an icon when party members have a defensive cooldown active (Pain Suppression, Ironbark, etc.)."], 250), 45)
            -- Suppressed when the ROW carries this tick. Still built in classic,
            -- where it is the page's only on/off control.
            if not tools2.hoistToggle then
                local defensiveEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Defensive Icon"], db, "defensiveIconEnabled", function()
                    tools2.refreshStates()
                    ApplyDefensive()
                end), 30)
                defensiveEnable.keepEnabled = true
            end
            group.disableChildrenOn = HideDefensiveIconOptions

            group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], db, "defensiveIconHideSwipe", function()
                ApplyDefensive()
            end), 30)
        end

        -- The one tick the row does not carry, in its own words. Silent while it is
        -- off, which is the shipped profile.
        local function DefensiveSettingsSummary(d)
            if not d then return "" end
            if not d.defensiveIconHideSwipe then return "" end
            return L["Hide Cooldown Swipe"]
        end

        if classicLayout then
            local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
            settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), 40)
            BuildDefensiveSettingsGroup({
                group = settingsGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(settingsGroup, nil, 1)
        else
            -- Two: the blurb and Hide Cooldown Swipe. The Enable tick is HOISTED
            -- onto the row.
            local DEFENSIVE_SETTINGS_COUNT = 2

            -- What the suppressed Enable checkbox ran, plus a repaint of every pane
            -- standing open -- eight of which grey with it. Never a page rebuild:
            -- that would retire the row being clicked through.
            local function OnDefensiveEnableToggle()
                self:RefreshStates()
                ApplyDefensive()
                tools.ReflowMounted()
            end

            local settingsMount, settingsContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensiveSettingsGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local settingsRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Settings"],
                db       = tools.RowDB,
                toggle   = { key = "defensiveIconEnabled" },
                summary  = DefensiveSettingsSummary,
                count    = DEFENSIVE_SETTINGS_COUNT,
                onToggle = OnDefensiveEnableToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = settingsMount,
            }))
            tools.ClaimKeys(settingsRow, settingsContent)
            tools.WireModifiedTick(settingsRow)
            tools.WireFooter(settingsRow, ApplyDefensive)
            tools.RegisterHoistedToggle(settingsRow, L["Enable Defensive Icon"], "defensiveIconEnabled", OnDefensiveEnableToggle)
        end

        -- ===== DEFENSIVE FILTERS (a 280 box in column 2 in classic, the Content
        -- band's second row) =====
        -- Category filter selection for the defensive row (Filter Registry
        -- presets + custom filters). Mirrors the Aura Filters page's buff
        -- selection list. Each row toggles a key inside
        -- db.defensiveFilterSelection — always mutate the inner tables in
        -- place (the aura pipeline holds references to them; never reassign).
        -- No Show All / Only Mine here: the defensive row resolves with
        -- showAll hard-false and has no such keys (see BuildDefensiveRowConfig).
        --
        -- ☠ IT READS SECOND, NOT SIXTH. In classic it is the sixth box on the page,
        -- below Border, because the columns had to balance; in a band there is
        -- nothing to balance, and "which cooldowns reach this icon" is the question
        -- that follows "is there an icon" -- the order the two bar pages already
        -- read in.
        local function BuildDefensiveFilterGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = HideDefensiveIconOptions

            -- Same sentence as the Buff Bar page's filter group, from one string:
            -- the two groups now do the same job for two consumers, and wording the
            -- rule twice is how they drift apart. It also drops "enabled" — the
            -- page's word for a checked box is "selected", everywhere.
            group:AddWidget(GUI:CreateLabel(parent,
                "|cff888888" .. L["Selected filters are combined — a buff matching any of them is shown."] .. "|r", 250), 35)

            local function SelectionCheckbox(labelText, getSel, setSel)
                return group:AddWidget(GUI:CreateCheckbox(parent, labelText, nil, nil, DefensiveFilterChanged, getSel, setSel), 30)
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

            -- ⚠ A PANE THE USER LEAVES THROUGH. Manage Filters is a tab switch, which
            -- rebuilds the page it lands on -- and CreatePopoutPageTools' own prologue
            -- closes every open panel on the way into that build. So the panel this
            -- button was clicked in is taken down by the page it opens, in the one
            -- order that is safe: the row it was wired to is still alive when it goes.
            local defManage = group:AddWidget(GUI:CreateButton(parent, L["Manage Filters"], 140, 22, function()
                if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
                    GUI.SelectTab("auras_filterdesigner")
                end
            end), 30)
            defManage.disableOn = function() return not (GUI.Pages and GUI.Pages["auras_filterdesigner"]) end
        end

        -- The page build is cached across tab switches, but preset counts and
        -- the custom-filter list can change while this page is hidden (Filter
        -- Designer edits). On show, invalidate the page cache when the registry
        -- signature moved so RefreshCached() rebuilds fresh rows instead of
        -- serving stale ones (same idiom as the Aura Filters page).
        --
        -- ⚠ AT PAGE SCOPE, OUTSIDE THE BUILDER. A pane is built once per INSTANCE
        -- (pin a panel and open the row again and there are two), and this block is
        -- about the PAGE -- one signature, one hook.
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

        -- ☠ THE ONE ROW ON THE PAGE WHOSE COUNT IS DATA. The pane mounts one tick
        -- per built-in category and one per custom filter the user has made, so the
        -- declared number has to be COUNTED rather than written down -- a literal
        -- would be wrong the moment somebody saves a filter.
        local function DefensiveFilterCount()
            local customs = 0
            for _ in pairs(R:ReadStore().customFilters) do customs = customs + 1 end
            -- The caption, the complement bucket and Manage Filters -- plus one row
            -- per category and one per custom filter.
            return 3 + #R.Categories + customs
        end

        -- What the row says with the panel shut: how much of the library is
        -- switched on, in the "11/13" shape the Buff Bar's filter row uses. There is
        -- no All Buffs / Only Mine on this page to qualify it with.
        local function DefensiveFilterSummary(d)
            if not d then return "" end
            local sel = d.defensiveFilterSelection or {}
            local presets, customs = sel.presets or {}, sel.customs or {}
            local on, total = 0, #R.Categories + 1   -- + the complement bucket
            for _, cat in ipairs(R.Categories) do
                if presets[cat.key] then on = on + 1 end
            end
            for cfId in pairs(R:ReadStore().customFilters) do
                total = total + 1
                if customs[cfId] then on = on + 1 end
            end
            if sel.uncategorised then on = on + 1 end
            return format("%d/%d", on, total)
        end

        -- ===== LAYOUT (a 280 box in column 1 in classic, the Icon band's first
        -- row) =====
        local function BuildDefensiveLayoutGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent, L["Controls how multiple defensive icons are arranged."], 250), 45)
            group.disableChildrenOn = HideDefensiveIconOptions

            group:AddWidget(GUI:CreateGrowthControl(parent, db, "defensiveBarGrowth", function()
                ApplyDefensive()
            end), 155)
            group:AddWidget(GUI:CreateSlider(parent, L["Max Icons"], 1, 5, 1, db, "defensiveBarMax", function()
                ApplyDefensive()
            end, nil, true), 55)

            local defSortDrop = group:AddWidget(GUI:CreateDropdown(parent, L["Sort Order"], defSortOptions, db, "defensiveSortOrder", function()
                ApplyDefensive()
            end), 55)
            defSortDrop.hideOn = NoFactoryRow
            defSortDrop.tooltip = L["Externals First: defensives cast on this player by others show first, their own last. Most Urgent: soonest to expire first."]

            local defWrap = group:AddWidget(GUI:CreateSlider(parent, L["Icons Per Row"], 1, 5, 1, db, "defensiveBarWrap", function()
                ApplyDefensive()
            end, nil, true), 55)
            -- Greys out on vertical-primary growth, where the native row-primary flow renders a
            -- single column and there is nothing for a per-row count to do. Normal contextual
            -- state via the grey seam, NOT a 12.1 frost — the control works horizontally, and the
            -- blocked registry is for things the game genuinely cannot do. Mirrors the Buffs page,
            -- including its 68914 re-verification of the flow-layout options.
            --
            -- ☠ AND THE GROWTH IT READS IS SET IN THE SAME PANE, which is why nothing
            -- extra is needed here: the growth control's own write ends in a state
            -- pass, and in a pane that pass is the reflow.
            defWrap.disableOn = function(d)
                local g = d.defensiveBarGrowth or ""
                -- Vertical-primary AND vertical-centred growth both render a single column.
                return DF:FactoryOwnsDefensiveRow(d) and (g:sub(1, 2) == "UP" or g:sub(1, 4) == "DOWN"
                    or g == "CENTER_LEFT" or g == "CENTER_RIGHT")
            end

            group:AddWidget(GUI:CreateSlider(parent, L["Spacing"], -10, 10, 1, db, "defensiveBarSpacing", function()
                ApplyDefensive()
            end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        end

        -- How many icons, and in what order -- the two facts a shut row can state
        -- about an arrangement. The sort word comes out of the same table the
        -- dropdown offers, and is silent on a client that cannot honour it.
        local function DefensiveLayoutSummary(d)
            if not d then return "" end
            local parts = {}
            local n = tonumber(d.defensiveBarMax)
            if n then parts[#parts + 1] = format("%s %d", L["Max Icons"], n) end
            local sort = defSortOptions[d.defensiveSortOrder]
            if sort and not NoFactoryRow(d) then parts[#parts + 1] = sort end
            return Join(parts)
        end

        -- ===== APPEARANCE (a 280 box in column 2 in classic, the Icon band's
        -- second row) =====
        local function BuildDefensiveAppearanceGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = HideDefensiveIconOptions

            group:AddWidget(GUI:CreateSlider(parent, L["Icon Size"], 12, 48, 1, db, "defensiveIconSize", function()
                ApplyDefensive()
            end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)

            group:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 4.0, 0.1, db, "defensiveIconScale", function()
                ApplyDefensive()
            end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)

            group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, "defensiveIconFrameLevel", function()
                ApplyDefensive()
            end, function() DF:LightweightUpdateFrameLevel("defensive") end, true)), 55)
        end

        -- Pixels first, then the multiplier, and the multiplier only while it is
        -- doing something -- a row reading "Scale 1.00" on every default profile is
        -- noise. Frame Level is left out: it is a stacking-order fix, not a look.
        local function DefensiveAppearanceSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.defensiveIconSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local scale = tonumber(d.defensiveIconScale)
            if scale and scale ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Scale"], scale) end
            return Join(parts)
        end

        -- ===== POSITION (a 280 box in column 1 in classic, the Icon band's third
        -- row) =====
        local function BuildDefensivePositionGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = HideDefensiveIconOptions

            group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, "defensiveIconAnchor", function()
                ApplyDefensive()
            end), 55)

            group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -100, 100, 1, db, "defensiveIconX", function()
                ApplyDefensive()
            end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)

            group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -100, 100, 1, db, "defensiveIconY", function()
                ApplyDefensive()
            end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        end

        local function DefensivePositionSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.defensiveIconAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local x, y = tonumber(d.defensiveIconX) or 0, tonumber(d.defensiveIconY) or 0
            if x ~= 0 or y ~= 0 then parts[#parts + 1] = format("%d, %d", x, y) end
            return Join(parts)
        end

        -- ===== BORDER (a 280 box in column 2 in classic, the Icon band's fourth
        -- row) =====
        -- Canonical border controls via the unified helper. include opts in
        -- inset / offset / blendMode / gradient / shadow on top of the
        -- always-present Show / Style / Texture / Size / Colour. Inset moves
        -- the border edges inward (positive) or outward (negative) relative
        -- to the icon's bounds — independent of borderSize (thickness) and
        -- independent of the artwork's own inset.
        --
        -- ⚠ noShowToggle IS THE HOIST -- the Pet Frames / Resource Bar / Buff Bar
        -- border row's move, verbatim. With it the built-in Show Border checkbox is
        -- not built and the row carries that tick instead; the show key is still
        -- read, so it still greys the other eighteen exactly as before.
        local function BuildDefensiveBorderGroup(tools2)
            GUI:CreateBorderControls(tools2.group, db, "defensiveIcon", {
                parent       = tools2.parent,
                -- Class/Role colour makes sense here: at a glance, the border
                -- communicates WHO is using the defensive cooldown (their class
                -- or role) without the user having to read the icon. (Animation is
                -- not offered: the defensive icon is a container button, and 12.1
                -- forbids driving its border while auras are secret — see
                -- AuraContainer's animation chokepoint.)
                include      = { inset = true, offset = true, blendMode = true,
                                 gradient = true, shadow = true, alpha = true,
                                 classColor = true, roleColor = true },
                fullUpdate   = function() ApplyDefensive() end,
                lightUpdate  = function() DF:LightweightUpdateDefensiveIcons() end,
                lightColors  = function() DF:LightweightUpdateDefensiveIconColors() end,
                refreshStates = tools2.refreshStates,
                noShowToggle = tools2.hoistToggle or nil,
            })
            -- No hideWhen: the group gate below is what handles the feature being
            -- off, and it GREYS like every other box on this page. (This call used to
            -- pass both, so the controls vanished before the grey could show.)
            tools2.group.disableChildrenOn = HideDefensiveIconOptions
        end

        -- The Buff Bar's border summary, unchanged: thickness in pixels, the style
        -- word, and the alpha only when it is doing something.
        local function DefensiveBorderSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.defensiveIconBorderSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local style = d.defensiveIconBorderStyle
            parts[#parts + 1] = (style == "GRADIENT" and L["Gradient"])
                             or (style == "TEXTURE" and L["Texture"])
                             or L["Solid"]
            local c = d.defensiveIconBorderColor
            local a = type(c) == "table" and tonumber(c.a) or nil
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            return Join(parts)
        end

        -- ===== DURATION TEXT (a 280 box in column 1 in classic, the Text band's
        -- first row) =====
        --
        -- Sub-controls HIDE when Show Duration is off (variant gate); they GREY
        -- via the group's disableChildrenOn when the feature itself is disabled.
        local function HideDefensiveDurationOptions(d)
            return not d.defensiveIconShowDuration
        end

        local function BuildDefensiveDurationGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = HideDefensiveIconOptions
            -- Suppressed when the ROW carries this tick. Still built in classic,
            -- where it is the group's only on/off control.
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], db, "defensiveIconShowDuration", function()
                    tools2.refreshStates()
                    ApplyDefensive()
                end), 30)
            end

            -- One widget now, so hideOn covers the example too — no second predicate to keep
            -- in step (see CreateDurationFormatControls).
            local defDurFormat = GUI:CreateDurationFormatControls(parent, group, defDurFormatOptions, db, "defensiveIconDurationFormat", function() DF:InvalidateAuraLayout(); DF:UpdateAllFrames() end)
            defDurFormat.hideOn = HideDefensiveDurationOptions

            -- Shared TextStyle control block (font/scale/outline/shadow/colour/anchor/
            -- offsets/justify). The offsets/anchor honor the existing defensiveIconDurationX/Y
            -- keys (previously config-only); the static colour greys while Color-by-Time owns it.
            GUI:CreateTextControls(group, db, "defensiveIconDuration", {
                parent     = parent,
                include    = { color = true },
                colorLabel = L["Duration Color"],
                hideOn     = HideDefensiveDurationOptions,
                colorDisableOn = function(d) return d.defensiveIconDurationColorByTime end,
                onChange   = function() ApplyDefensive() end,
                onDrag     = function() DF:LightweightUpdateDefensiveIcons() end,
            })

            local diDurColorByTime = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], db, "defensiveIconDurationColorByTime", function()
                tools2.refreshStates()
                ApplyDefensive()
            end), 30)
            diDurColorByTime.hideOn = HideDefensiveDurationOptions
            local diColorsLink = AddColorsPageLink(group, parent)
            diColorsLink.hideOn = HideDefensiveDurationOptions

            local diDurHidePerm = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration on Permanent Auras"], db, "defensiveIconDurationHideOnPermanent", function()
                ApplyDefensive()
            end), 30)
            diDurHidePerm.hideOn = HideDefensiveDurationOptions
        end

        -- (The old "Duration Position" group is gone: CreateTextControls above already
        -- renders Anchor + Offset X/Y on the same defensiveIconDurationX/Y keys — the
        -- separate group was a duplicate left behind by the TextStyle conversion.)

        -- Which of the four icon-sized formats the text is drawn in, in the
        -- dropdown's own words -- and the one option that takes the colour away
        -- from the swatch behind it.
        local function DefensiveDurationSummary(d)
            if not d then return "" end
            local parts = {}
            local fmt = defDurFormatOptions[d.defensiveIconDurationFormat]
            if fmt then parts[#parts + 1] = fmt end
            if d.defensiveIconDurationColorByTime then parts[#parts + 1] = L["Color by Time Remaining"] end
            return Join(parts)
        end

        -- ===== STACK COUNT (a 280 box in column 1 in classic, the Text band's
        -- second row) =====
        -- Directly under Duration, matching the Buffs page and the Aura Designer cards:
        -- the two text elements on an icon are tuned as a pair, so a user who finds one
        -- expects the other adjacent. Until now this page had only the duration half —
        -- the stack text was a hardcoded 14pt in Features/Auras.lua with no keys at all,
        -- which a user hit when 12.1 pushed some counts to three digits (report,
        -- 2026-08-13: "I can only change the duration text for it").
        -- ☠ FULL CONTROLS, INCLUDING COLOUR, WITH NO DEFAULT COLOUR KEY. Those are not in
        -- tension: CreateColorPicker seeds {1,1,1,1} inside its own OnClick when the key
        -- is absent, and UpdateSwatch skips a nil key entirely — so the control works and
        -- writes NOTHING until a user actually picks a colour. Until then BuildSpec reads
        -- nil and TextStyle leaves the colour alone, exactly as the old hardcoded table
        -- did by omission.
        -- ⚠ That is why `defensiveIconStackColor` has no Config default and must not gain
        -- one. A seeded default would restyle every existing profile the moment they
        -- update, and nobody has established what the untouched native colour actually is
        -- — the picker's white is its own fallback, not a measurement.
        local function BuildDefensiveStackGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            GUI:CreateTextControls(group, db, "defensiveIconStack", {
                parent     = parent,
                include    = { color = true },
                colorLabel = L["Stack Text Color"],
                onChange   = function() ApplyDefensive() end,
                onDrag     = function() DF:LightweightUpdateDefensiveIcons() end,
            })
            -- Grey with the feature, same as the Duration group above.
            group.disableChildrenOn = HideDefensiveIconOptions
        end

        -- Where the number sits and how big it is -- the two facts a styling row can
        -- state without opening. The anchor word comes out of the same nine-way
        -- table the TextStyle block's own dropdown offers.
        local function DefensiveStackSummary(d)
            if not d then return "" end
            local parts = {}
            local anchor = anchorOptions[d.defensiveIconStackAnchor]
            if anchor then parts[#parts + 1] = anchor end
            local scale = tonumber(d.defensiveIconStackScale)
            if scale and scale ~= 1 then parts[#parts + 1] = format("%s %.2f", L["Scale"], scale) end
            return Join(parts)
        end

        -- ===== DURATION BAR (a 280 box in column 1 in classic, the headerless
        -- band's only row) ===== (12.1 factory rows only — mirrors the Buffs page's
        -- block; UpdateAllDefensiveBars bumps the layout version, and the sig split
        -- routes Rebuild vs in-place restyle)
        local function BuildDefensiveDurationBarGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateLabel(parent, L["Shows a bar on each icon that drains with the aura's remaining time."], 250), 30)
            if not tools2.hoistToggle then
                local defBarEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Duration Bar"], db, "defensiveDurationBarEnabled", function()
                    tools2.refreshStates()
                    DefBarChanged()
                end), 30)
                defBarEnable.keepEnabled = true
                defBarEnable.disableOn = HideDefensiveIconOptions
            end
            group.disableChildrenOn = function(d) return not d.defensiveIconEnabled or not d.defensiveDurationBarEnabled end
            group:AddWidget(GUI:CreateDropdown(parent, L["Position"], defBarPositionOptions, db, "defensiveDurationBarPosition", DefBarChanged), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Height"], 1, 12, 1, db, "defensiveDurationBarHeight", nil, DefBarChanged, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Gap"], 0, 10, 1, db, "defensiveDurationBarGap", nil, DefBarChanged, true), 55)
            group:AddWidget(GUI:CreateDropdown(parent, L["Color Mode"], DF:GetDurationBarColorModes(), db, "defensiveDurationBarColorMode", function()
                tools2.refreshStates()
                DefBarChanged()
            end), 55)
            local defBarTex = group:AddWidget(GUI:CreateTextureDropdown(parent, L["Texture"], db, "defensiveDurationBarTexture", DefBarChanged), 55)
            local defBarCol = group:AddWidget(GUI:CreateColorPicker(parent, L["Bar Color"], db, "defensiveDurationBarColor", true, DefBarChanged), 30)
            -- A curve mode brings its own ramp texture and forces white, so these two do
            -- nothing while it is selected - dim them rather than leave dead controls live.
            defBarTex.disableOn = function(d) return DF:IsDurationBarCurveMode(d.defensiveDurationBarColorMode) end
            defBarCol.disableOn = defBarTex.disableOn
            group:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], db, "defensiveDurationBarBGColor", true, DefBarChanged), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Reverse Fill"], db, "defensiveDurationBarReverseFill", DefBarChanged), 30)
        end

        local function DefensiveDurationBarSummary(d)
            if not d then return "" end
            local parts = {}
            local pos = defBarPositionOptions[d.defensiveDurationBarPosition]
            if pos then parts[#parts + 1] = pos end
            local h = tonumber(d.defensiveDurationBarHeight)
            if h then parts[#parts + 1] = format("%dpx", math.floor(h)) end
            local modes = DF:GetDurationBarColorModes()
            local mode = modes and modes[d.defensiveDurationBarColorMode]
            if mode then parts[#parts + 1] = mode end
            return Join(parts)
        end

        -- ===== THE MOUNTS, IN THE ORDER CLASSIC ADDS THEM =================
        -- ⚠ THE CLASSIC ARMS RUN IN THE PAGE'S OWN Add ORDER, which is what makes
        -- "classic is unchanged" structural: within a column the Add() order IS the
        -- layout order. The BANDS are added at the foot, so the popout layout reads
        -- in its own order without disturbing that.

        if classicLayout then
            local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
            layoutGroup:AddWidget(GUI:CreateHeader(self.child, L["Layout"]), 40)
            BuildDefensiveLayoutGroup({
                group = layoutGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(layoutGroup, nil, 1)
        else
            -- Six: the blurb, the growth control (one widget, three stacked mini
            -- dropdowns inside it), Max Icons, the sort pick, Icons Per Row and the
            -- spacing.
            local DEFENSIVE_LAYOUT_COUNT = 6

            local layoutMount, layoutContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensiveLayoutGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local layoutRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Layout"],
                db      = tools.RowDB,
                summary = DefensiveLayoutSummary,
                count   = DEFENSIVE_LAYOUT_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = layoutMount,
            }))
            -- ⚠ defensiveBarGrowth IS NAMED, because the walk cannot see it. The
            -- growth control is three hand-built mini dropdowns in a container -- it
            -- registers nothing with search and carries no dbKey -- so without this
            -- the row's tick and its Reset Group would both act as though the setting
            -- were on another page.
            tools.ClaimKeys(layoutRow, layoutContent, { "defensiveBarGrowth" })
            tools.WireModifiedTick(layoutRow)
            tools.WireFooter(layoutRow, ApplyDefensive)
            layoutRow.disableOn = DefensiveOffRow
        end

        if classicLayout then
            local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
            appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)
            BuildDefensiveAppearanceGroup({
                group = appearanceGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(appearanceGroup, nil, 2)
        else
            -- Three: size, scale and the frame level.
            local DEFENSIVE_APPEARANCE_COUNT = 3

            local appearanceMount, appearanceContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensiveAppearanceGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local appearanceRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Appearance"],
                db      = tools.RowDB,
                summary = DefensiveAppearanceSummary,
                count   = DEFENSIVE_APPEARANCE_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = appearanceMount,
            }))
            tools.ClaimKeys(appearanceRow, appearanceContent)
            tools.WireModifiedTick(appearanceRow)
            tools.WireFooter(appearanceRow, ApplyDefensive)
            appearanceRow.disableOn = DefensiveOffRow
        end

        if classicLayout then
            local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
            positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
            BuildDefensivePositionGroup({
                group = positionGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(positionGroup, nil, 1)
        else
            -- Three: the anchor and the two offsets.
            local DEFENSIVE_POSITION_COUNT = 3

            local positionMount, positionContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensivePositionGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local positionRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Position"],
                db      = tools.RowDB,
                summary = DefensivePositionSummary,
                count   = DEFENSIVE_POSITION_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = positionMount,
            }))
            tools.ClaimKeys(positionRow, positionContent)
            tools.WireModifiedTick(positionRow)
            tools.WireFooter(positionRow, ApplyDefensive)
            positionRow.disableOn = DefensiveOffRow
        end

        if classicLayout then
            local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
            borderGroup:AddWidget(GUI:CreateHeader(self.child, L["Border"]), 40)
            BuildDefensiveBorderGroup({
                group = borderGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(borderGroup, nil, 2)
        else
            -- Eighteen: the nineteen CreateBorderControls builds for this include
            -- set -- the toolkit's usual set plus the Colour Source dropdown the two
            -- resolver opt-ins add -- less the hoisted Show Border.
            local DEFENSIVE_BORDER_COUNT = 18

            -- What the suppressed Show Border checkbox ran, and never a page
            -- rebuild: that would retire every widget on the page including the row
            -- being clicked through.
            local function OnDefensiveBorderToggle()
                self:RefreshStates()
                ApplyDefensive()
                tools.ReflowMounted()
            end

            local borderMount, borderContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensiveBorderGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
                GatePaneFirstChild(group)
            end)
            local borderRow = iconBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Border"],
                db       = tools.RowDB,
                toggle   = { key = "defensiveIconShowBorder" },
                summary  = DefensiveBorderSummary,
                count    = DEFENSIVE_BORDER_COUNT,
                onToggle = OnDefensiveBorderToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = borderMount,
            }))
            tools.ClaimKeys(borderRow, borderContent)
            tools.WireModifiedTick(borderRow)
            tools.WireFooter(borderRow, ApplyDefensive)
            tools.RegisterHoistedToggle(borderRow, L["Show Border"], "defensiveIconShowBorder", OnDefensiveBorderToggle)
            borderRow.disableOn = DefensiveOffRow
        end

        if classicLayout then
            local filterGroup = GUI:CreateSettingsGroup(self.child, 280)
            filterGroup:AddWidget(GUI:CreateHeader(self.child, L["Defensive Filters"]), 40)
            BuildDefensiveFilterGroup({
                group = filterGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(filterGroup, nil, 2)
        else
            local filterMount, filterContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensiveFilterGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
            end)
            local filterRow = contentBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Defensive Filters"],
                db      = tools.RowDB,
                summary = DefensiveFilterSummary,
                count   = DefensiveFilterCount(),
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = filterMount,
            }))
            -- ⚠ THE SELECTION TABLE IS NAMED, because the walk cannot see it. Every
            -- filter tick is a CUSTOM get/set checkbox -- it has no db binding at all,
            -- so what it registers with search is a synthetic `custom_<label>` key and
            -- the real setting, `defensiveFilterSelection`, is bound to nothing the
            -- walk can find.
            tools.ClaimKeys(filterRow, filterContent, { "defensiveFilterSelection" })
            tools.WireModifiedTick(filterRow)
            -- ☠ NO FOOTER ON THIS ROW, AND IT IS A REFUSAL RATHER THAN AN OMISSION.
            -- The Buff Bar's, key for key: Reset Group writes `db[key] =
            -- DeepCopy(default)` (GUI/GroupActions.lua), which for
            -- defensiveFilterSelection REPLACES the table -- and the note at the top
            -- of this group says why that cannot happen: the aura pipeline holds
            -- references to that table and its inner tables, so a fresh one strands
            -- every holder. Hold: Defaults is the same write twice over. This is the
            -- Debuff Filters row's opposite: THAT group's keys are all scalars, so a
            -- reset writes values and a footer is safe.
            filterRow.disableOn = DefensiveOffRow
        end

        -- ⚠ ONE SIGNATURE AND ONE HOOK PER PAGE BUILD, in both layouts. The block
        -- runs after whichever arm built the list, exactly where it ran when the
        -- list was straight-line code inside the box.
        self.dfDefFilterSignature = RegistrySignature()
        if not self.dfDefFilterSigHooked then
            self.dfDefFilterSigHooked = true
            self:HookScript("OnShow", function(page)
                if page.dfDefFilterSignature ~= RegistrySignature() then
                    page:Invalidate()
                end
            end)
        end

        if classicLayout then
            local durationGroup = GUI:CreateSettingsGroup(self.child, 280)
            durationGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Text"]), 40)
            BuildDefensiveDurationGroup({
                group = durationGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(durationGroup, nil, 1)
        else
            -- Twelve: the format control, the TextStyle block's eight, Color by Time
            -- and its cross-link, and the permanent-aura tick. The Show Duration tick
            -- is HOISTED onto the row.
            local DEFENSIVE_DURATION_COUNT = 12

            -- ☠ AND THE REFLOW IS NOT OPTIONAL ON THIS ONE. Every control behind
            -- this row carries hideOn rather than disableOn -- which is what classic
            -- does, and is left alone -- so switching the tick off empties the pane
            -- and switching it on refills it. The pane is where that has to happen,
            -- because a page rebuild would retire the row being clicked through.
            local function OnDefensiveDurationToggle()
                self:RefreshStates()
                ApplyDefensive()
                tools.ReflowMounted()
            end

            local durationMount, durationContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensiveDurationGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
                GatePaneFirstChild(group)
            end)
            local durationRow = textBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Duration Text"],
                db       = tools.RowDB,
                toggle   = { key = "defensiveIconShowDuration" },
                summary  = DefensiveDurationSummary,
                count    = DEFENSIVE_DURATION_COUNT,
                onToggle = OnDefensiveDurationToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = durationMount,
            }))
            tools.ClaimKeys(durationRow, durationContent)
            tools.WireModifiedTick(durationRow)
            tools.WireFooter(durationRow, ApplyDefensiveDurationText)
            tools.RegisterHoistedToggle(durationRow, L["Show Duration"], "defensiveIconShowDuration", OnDefensiveDurationToggle)
            durationRow.disableOn = DefensiveOffRow
        end

        if classicLayout then
            local defStackGroup = GUI:CreateSettingsGroup(self.child, 280)
            defStackGroup.hideOn = NoFactoryRow
            defStackGroup:AddWidget(GUI:CreateHeader(self.child, L["Stack Count"]), 40)
            BuildDefensiveStackGroup({
                group = defStackGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(defStackGroup, nil, 1)
        else
            -- Eight: the TextStyle block's font, scale, outline, shadow, colour,
            -- anchor and two offsets.
            local DEFENSIVE_STACK_COUNT = 8

            local stackMount, stackContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensiveStackGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                })
                GatePaneFirstChild(group)
            end)
            local stackRow = textBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Stack Count"],
                db      = tools.RowDB,
                summary = DefensiveStackSummary,
                count   = DEFENSIVE_STACK_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = stackMount,
            }))
            -- The box's own hideOn becomes the ROW's, so the band collapses the slot
            -- rather than leaving a gap where a count the client cannot style would be.
            stackRow.hideOn = NoFactoryRow
            tools.ClaimKeys(stackRow, stackContent)
            tools.WireModifiedTick(stackRow)
            tools.WireFooter(stackRow, ApplyDefensive)
            stackRow.disableOn = DefensiveOffRow
        end

        if classicLayout then
            local durBarGroup = GUI:CreateSettingsGroup(self.child, 280)
            durBarGroup.hideOn = NoFactoryRow
            durBarGroup:AddWidget(GUI:CreateHeader(self.child, L["Duration Bar"]), 40)
            BuildDefensiveDurationBarGroup({
                group = durBarGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(durBarGroup, nil, 1)
        else
            -- Nine: the blurb, the position pick, height, gap, the colour mode, the
            -- texture and two colours, and Reverse Fill. The Enable tick is HOISTED.
            local DEFENSIVE_DURBAR_COUNT = 9

            local function OnDefensiveDurationBarToggle()
                self:RefreshStates()
                DefBarChanged()
                tools.ReflowMounted()
            end

            local durBarMount, durBarContent = tools.PopoutContent(function(group, holder, reflow)
                BuildDefensiveDurationBarGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    popout = true,
                    hoistToggle = true,
                })
            end)
            local durBarRow = factoryBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Duration Bar"],
                db       = tools.RowDB,
                toggle   = { key = "defensiveDurationBarEnabled" },
                summary  = DefensiveDurationBarSummary,
                count    = DEFENSIVE_DURBAR_COUNT,
                onToggle = OnDefensiveDurationBarToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = durBarMount,
            }))
            -- The box's own hideOn becomes the ROW's, so the band collapses the slot
            -- rather than leaving a gap where a bar the client cannot draw would be.
            durBarRow.hideOn = NoFactoryRow
            tools.ClaimKeys(durBarRow, durBarContent)
            tools.WireModifiedTick(durBarRow)
            tools.WireFooter(durBarRow, DefBarChanged)
            tools.RegisterHoistedToggle(durBarRow, L["Enable Duration Bar"], "defensiveDurationBarEnabled", OnDefensiveDurationBarToggle)
            -- The suppressed Enable tick carried this gate itself; with the tick on
            -- the row, the row is the only place left to say it.
            durBarRow.disableOn = DefensiveOffRow
        end

        -- ===== THE FOUR BANDS, IN READING ORDER ===========================
        -- Added at the foot rather than in place: every band is full width, so there
        -- is no column flow left to unbalance and the order below is purely the
        -- order the page reads in.
        if not classicLayout then
            Add(contentBand, nil, "both")
            Add(iconBand, nil, "both")
            Add(textBand, nil, "both")
            Add(factoryBand, nil, "both")
        end

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
            -- Reflect it in test mode, matching the Targeted List enable above. This
            -- is the owner of the personal preview and gates on the same master
            -- Enable, so it resolves the display in both directions.
            if DF.UpdateAllTestTargetedSpell then DF:UpdateAllTestTargetedSpell() end
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
