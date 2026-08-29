-- Part 2 of the settings pages, split from Options.lua.
-- The parts run as a chain so the pages build in their original order.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local format = string.format
function DF._SetupGUIPagesPart2(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
    local pageGlobalFonts = CreateSubTab("general", "general_fonts", L["Global Fonts"])
    BuildPage(pageGlobalFonts, function(self, db, Add, AddSpace, AddSyncPoint)
        Add(CreateCopyButton(self.child, {"fontShadow"}, L["Global Fonts"], "general_fonts"), 25, 2)
        -- Initialize temp storage for selections (persists during session)
        --
        -- ☠ IT STAYS HERE, AT PAGE SCOPE, IN BOTH LAYOUTS. The three selectors
        -- below are bound to this table, and it is SEEDED FROM THE PROFILE -- so
        -- moving it inside a builder would move WHEN it runs: once per pane
        -- instance in the popout layout, and never at all on a build where the
        -- user does not open the row. Where a build writes is exactly what the
        -- export byte-identity gate measures.
        if not DF.GlobalFontTemp then
            DF.GlobalFontTemp = {
                font = db.nameFont or "Fonts\\FRIZQT__.TTF",
                outline = db.nameTextOutline or "OUTLINE",
            }
        end

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: three 280 boxes, two in column
        -- one and the reference list in column two. POPOUT turns the two REAL
        -- groups into feature rows -- Global Font Settings, Shadow Settings --
        -- and keeps Affected Elements as a FULL-WIDTH box wearing the band skin.
        --
        -- ⚠ AFFECTED ELEMENTS STAYS A BOX ON A JUDGEMENT, not on the
        -- single-option rule the other pages leaned on: it holds a header, a
        -- twelve-line list and a caution note, and ZERO controls. A row buys a
        -- page space by folding controls away behind a click; folding away pure
        -- reference text -- the list a user reads WHILE deciding whether to press
        -- Apply to All -- buys nothing and hides the one thing on the page that
        -- is there to be read. And with no control in it there is nothing a
        -- CONTROL ROW could carry either, so a box is what it stays.
        --
        -- ☠ WHAT IT DOES NOT STAY IS 280 WIDE. A narrower rectangle with its own
        -- border and its own left edge, standing beside a full-width band, is the
        -- one thing a column of plates cannot absorb -- so it is built at the
        -- BAND's width and added as a sync point, and the page's two top-level
        -- objects then start and end on the same two edges. That is the pet-frame
        -- boxes' answer (Pages/Options.lua), and it comes with their warning: a
        -- box built at the band width but added to a COLUMN would be worse than
        -- what it replaced, because the layout pass only stretches a "both" widget
        -- and never narrows a column one (GUI/Panel.lua's LayoutPage).
        --
        -- Every converted group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates }. The classic branch mounts the SAME
        -- builder into the box it always built, which is what makes "classic is
        -- unchanged" structural rather than a promise --
        -- test_globalfonts_page_builders.lua pins the inventory of each one
        -- against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery: eager holders, pane reflow, the key
        -- claim, the amber tick, the footer's Reset Group / Hold: Defaults, the
        -- hoisted-toggle search repair and the band width. nil in classic, which
        -- is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ===== THE PAGE'S ONE BAND ========================================
        -- Full-width and chromeless: a feature row's popout docks outside the
        -- WINDOW and runs a beam back to the row, so a row that stopped 280px in
        -- would leave that beam crossing half the page.
        --
        -- ⚠ NO HEADER ON IT. A header names a SECTION, and the two rows' own
        -- labels -- "Global Font Settings" and "Shadow Settings" -- already carry
        -- the page's one subject between them; a "Global Fonts" header above them
        -- would only repeat the tab the user just clicked. That is the Frame
        -- page's band rule: a band earns a header only when its rows share a word
        -- none of them says alone.
        local fontBand
        if tools then
            fontBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
        end

        -- The shadow group's two applies, at PAGE scope rather than inside the
        -- builder: they close over nothing group-specific, and the classic box and
        -- every pane instance must drive the same work.
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

        -- ===== FONT SELECTION (a 280 box in classic, the band's first row) =
        -- Verbatim, taking the group and parent it should build into: same
        -- factories, same L keys, same db tables and keys, same slot heights.
        --
        -- ⚠ THE APPLY BUTTON IS HAND-BUILT AND STAYS THAT WAY. It is not a
        -- settings widget -- it is a WIZARD action that writes ~30 per-mode font
        -- keys plus the Aura Designer and Text Designer configs in one press -- so
        -- there is no shared helper it belongs to, and its OnClick body is carried
        -- across UNCHANGED. Rewriting any of it here would be a settings-write
        -- change smuggled in under a layout pass.
        local function BuildFontSelectionGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Set a font and outline style, then click Apply to update ALL text elements."], 250), 40)

            group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], DF.GlobalFontTemp, "font", function() end), 55)

            group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], DF.GlobalFontTemp, "outline", function() end), 55)
            group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], DF.GlobalFontTemp, "outline", function() end), 30)

            -- Themed Apply button
            local applyBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
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
                -- ☠ Field report (5.1.3): this block silently did nothing. Three holes:
                --   1. `if defaults then` skipped the whole write when the table was absent.
                --   2. adDB.auras is SPEC-KEYED (auras[spec][auraName]) since the spec-scope
                --      migration, and the old loop iterated one level short — the instance
                --      clearing never matched anything, while EnsureTypeConfig stamps fonts
                --      on every placed indicator at creation, so instances shadowed the
                --      defaults write forever.
                --   3. Layout / Other / debuff-category GROUPS carry their text style on
                --      group.style with NO adDB.defaults fallback — untouched entirely.
                local _adMode = (db == DF.db.raid) and "raid" or "party"
                local _adCfg = (DF.GetModeBaseAuraDesigner and DF:GetModeBaseAuraDesigner(_adMode))
                    or (DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(_adMode))
                if _adCfg then
                    if not _adCfg.defaults then _adCfg.defaults = {} end
                    local adDefaults = _adCfg.defaults
                    adDefaults.durationFont = font; adDefaults.durationOutline = outline
                    adDefaults.stackFont = font; adDefaults.stackOutline = outline
                    -- Clear per-instance font overrides so indicators inherit the
                    -- defaults written above. Covers the post-migration indicators
                    -- array AND the legacy per-type sub-tables ("icon"/"square"/"bar")
                    -- of a record the lazy instances migration hasn't touched yet.
                    local function _clearAuraRecord(rec)
                        if type(rec) ~= "table" then return end
                        if type(rec.indicators) == "table" then
                            for _, inst in ipairs(rec.indicators) do
                                if type(inst) == "table" then
                                    inst.durationFont = nil; inst.durationOutline = nil
                                    inst.stackFont = nil; inst.stackOutline = nil
                                end
                            end
                        end
                        -- ☠ Not ipairs over {rec.icon, rec.square, rec.bar}: a nil hole
                        -- (record with a bar but no icon) would end the walk early.
                        for _, tk in pairs({ "icon", "square", "bar" }) do
                            local t = rec[tk]
                            if type(t) == "table" then
                                t.durationFont = nil; t.durationOutline = nil
                                t.stackFont = nil; t.stackOutline = nil
                            end
                        end
                    end
                    if type(_adCfg.auras) == "table" then
                        for _, specAuras in pairs(_adCfg.auras) do
                            if type(specAuras) == "table" then
                                for _, rec in pairs(specAuras) do _clearAuraRecord(rec) end
                            end
                        end
                    end
                    if type(_adCfg.otherAuras) == "table" then
                        for _, rec in pairs(_adCfg.otherAuras) do _clearAuraRecord(rec) end
                    end
                    -- Group buttons: SET the style explicitly (the opposite move from the
                    -- indicator clearing) — group.style has no defaults chain to inherit
                    -- from, so nil here would just mean the hardcoded factory default.
                    local function _styleGroup(g)
                        if type(g) ~= "table" then return end
                        local s = g.style
                        if type(s) ~= "table" then s = {}; g.style = s end
                        s.durationFont = font; s.durationOutline = outline
                        s.stackFont = font; s.stackOutline = outline
                    end
                    if type(_adCfg.layoutGroups) == "table" then
                        for _, v in pairs(_adCfg.layoutGroups) do
                            if type(v) == "table" and v.id ~= nil then
                                _styleGroup(v)   -- pre-spec-scope flat array entry
                            elseif type(v) == "table" then
                                for _, g in pairs(v) do _styleGroup(g) end
                            end
                        end
                    end
                    if type(_adCfg.otherLayoutGroups) == "table" then
                        for _, g in pairs(_adCfg.otherLayoutGroups) do _styleGroup(g) end
                    end
                    if type(_adCfg.debuffGroups) == "table" then
                        for _, g in pairs(_adCfg.debuffGroups) do _styleGroup(g) end
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
                    -- Create-if-missing, same silent-skip hole the AD defaults had.
                    if not _tdCfg.globalDefaults then _tdCfg.globalDefaults = {} end
                    _tdCfg.globalDefaults.font = font
                    _tdCfg.globalDefaults.outline = outline
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
            group:AddWidget(applyBtn, 35)

            group:AddWidget(GUI:CreateCheckbox(parent, L["Crisp Font Rendering (SDF)"], DF.db, "fontSlug", function()
                if DF.ClearFontCache then DF:ClearFontCache() end
                DF:UpdateAllFrames()
                if GUI.SelectedMode == "raid" and DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
                if DF.ApplyPetSettings then DF:ApplyPetSettings() end
                if DF.RefreshTestFrames then DF:RefreshTestFrames() end
            end), 30)
            group:AddWidget(GUI:CreateLabel(parent, L["Renders text with signed-distance-field smoothing for sharper edges at any size. Applies to None and Outline styles only (not Monochrome, Thick, or Shadow)."], 250), 50)
        end

        -- ===== SHADOW SETTINGS (a 280 box in classic, the band's second row) =
        local function BuildShadowSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["These settings apply when using 'Shadow' outline style. Use larger offsets for more dramatic shadows."], 250), 40)

            group:AddWidget(GUI:CreateSlider(parent, L["Shadow X Offset"], -10, 10, 0.5, db, "fontShadowOffsetX", UpdateShadowSettings, LightweightShadowUpdate), 50)
            group:AddWidget(GUI:CreateSlider(parent, L["Shadow Y Offset"], -10, 10, 0.5, db, "fontShadowOffsetY", UpdateShadowSettings, LightweightShadowUpdate), 50)
            group:AddWidget(GUI:CreateColorPicker(parent, L["Shadow Color"], db, "fontShadowColor", true, UpdateShadowSettings, LightweightShadowUpdate, true), 40)
        end

        if classicLayout then
            -- ===== FONT SELECTION GROUP (Column 1) =====
            local fontSelectGroup = GUI:CreateSettingsGroup(self.child, 280)
            fontSelectGroup:AddWidget(GUI:CreateHeader(self.child, L["Global Font Settings"]), 40)
            BuildFontSelectionGroup({
                group = fontSelectGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(fontSelectGroup, nil, 1)

            -- ===== SHADOW SETTINGS GROUP (Column 1) =====
            local shadowGroup = GUI:CreateSettingsGroup(self.child, 280)
            shadowGroup:AddWidget(GUI:CreateHeader(self.child, L["Shadow Settings"]), 40)
            BuildShadowSettingsGroup({
                group = shadowGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            Add(shadowGroup, nil, 1)
        else
            -- ---- the font selection row ----------------------------------
            -- Seven: the blurb, the three selectors, the Apply button, and the
            -- SDF tick with its own blurb.
            local FONT_SELECTION_COUNT = 7

            local fontMount, fontContent = tools.PopoutContent(function(group, holder, reflow)
                BuildFontSelectionGroup({ group = group, parent = holder, refreshStates = reflow })
            end)
            local fontRow = fontBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Global Font Settings"],
                db      = tools.RowDB,
                count   = FONT_SELECTION_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = fontMount,
            }))
            -- ☠ NO SUMMARY, AND THAT IS THE HONEST ANSWER RATHER THAN A GAP.
            -- Nothing behind this row is applied state. The font and outline the
            -- two dropdowns show live in DF.GlobalFontTemp -- a SESSION SCRATCH
            -- table, seeded once from nameFont and then only ever read by the
            -- Apply button -- so a row printing them would announce a selection
            -- the user may never have pressed Apply on, over a page whose real
            -- fonts are per-element and set on a dozen other pages. The one key
            -- here that IS applied state, fontSlug, is a yes/no with no word
            -- worth spending. A one-liner would lie; the kit still shows the
            -- label and the count badge, which is what no summary is for.
            --
            -- ☠ CLAIM THE KEYS, BUT NO MODIFIED TICK AND NO FOOTER -- the
            -- Integrations row's rule, reached by the same road.
            --
            -- ClaimKeys does two jobs and the one wanted here is the SEARCH row
            -- map: it records which row owns a setting, so a hit on "Font",
            -- "Outline" or "Crisp Font Rendering (SDF)" can open the panel the
            -- control is behind. Without it those are findable in classic and
            -- unreachable in the popout layout.
            --
            -- The other job is the amber tick's key list, and that half is inert
            -- here on purpose. DF.Defaults (DandersFrames/Core/Defaults.lua)
            -- answers for DF.db.party / DF.db.raid / the stored raid baseline and
            -- nothing else, and NOT ONE of this row's keys lives there: "font" and
            -- "outline" are fields of the session scratch table, and fontSlug is
            -- at the DF.db ROOT, account-wide. So:
            --   * WireModifiedTick would ask "is fontSlug modified" of a per-mode
            --     table that has never held it -- the tick could never light.
            --   * WireFooter is worse than useless: Reset Group and Hold both
            --     write through that same engine, so they would stamp PER-MODE
            --     defaults for three keys that live elsewhere -- inventing
            --     settings in the wrong table while the values the row is
            --     actually showing sat untouched.
            tools.ClaimKeys(fontRow, fontContent)

            -- ---- the shadow settings row ---------------------------------
            -- The summary, per the page convention: at most four items, a fixed
            -- order, " \194\183 " between them, WORDS localised and numbers raw,
            -- every read guarded because a profile mid-migration may be missing
            -- any of these keys.
            --
            -- The offset pair and nothing else, and only when it is not 0,0 --
            -- the Border Shadow row's own convention for a pair of offsets. The
            -- colour is deliberately not in here: there is no word for a colour,
            -- and the row's modified tick already says when one has been changed.
            -- On a default profile this row prints nothing, which is correct.
            --
            -- ⚠ %g, NOT the Border Shadow row's %d. These two sliders step in
            -- HALVES (0.5) where the border's own step is a whole pixel, so
            -- flooring would print "0, 0" for a real half-pixel offset -- a
            -- summary saying the opposite of the state it is reporting. %g
            -- prints 1 as "1" and 0.5 as "0.5", which is the same "numbers raw"
            -- the convention asks for, at this page's resolution.
            local function ShadowSettingsSummary(d)
                if not d then return "" end
                local parts = {}
                local ox = tonumber(d.fontShadowOffsetX) or 0
                local oy = tonumber(d.fontShadowOffsetY) or 0
                if ox ~= 0 or oy ~= 0 then
                    parts[#parts + 1] = format("%g, %g", ox, oy)
                end
                return table.concat(parts, " \194\183 ")
            end

            -- Four, which is the whole group: the blurb, the two offsets and the
            -- colour. Nothing is hoisted -- there is no boolean in here meaning
            -- "am I doing anything" (the shadow style is chosen by the outline
            -- dropdown in the row above, and on a dozen other pages besides).
            local SHADOW_SETTINGS_COUNT = 4

            local shadowMount, shadowContent = tools.PopoutContent(function(group, holder, reflow)
                BuildShadowSettingsGroup({ group = group, parent = holder, refreshStates = reflow })
            end)
            local shadowRow = fontBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Shadow Settings"],
                db      = tools.RowDB,
                summary = ShadowSettingsSummary,
                count   = SHADOW_SETTINGS_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = shadowMount,
            }))
            -- ☠ THIS ROW CARRIES A SECTION ANCHOR, and it is the only one on the
            -- page that is jumped to from somewhere else. Every per-element
            -- "Shadow" checkbox in the addon sits under a link built by
            -- UI:CreateGlobalFontsShadowLink (DandersUI/Sections.lua), which is
            -- LinkToSetting{ page = "general_fonts", section = L["Shadow
            -- Settings"] } -- and that jump is Search:ScrollToSection, which finds
            -- a section by asking every page child, and every settings-group
            -- child, for :GetText(). In classic the box's own HEADER answers. In
            -- this layout no header is built at all: the row's name is a
            -- FontString INSIDE the row, which the walk never reaches.
            --
            -- ClaimKeys is what puts the answer back -- it stamps every row it is
            -- given with a GetText returning that row's own label, which is
            -- exactly this link's section name. So the line below is load-bearing
            -- for more than the search row map, and removing it would take this
            -- cross-link down with it in silence.
            tools.ClaimKeys(shadowRow, shadowContent)
            tools.WireModifiedTick(shadowRow)
            tools.WireFooter(shadowRow, UpdateShadowSettings)
            -- ⚠ NO hideOn AND NO disableOn, which mirrors classic exactly: the
            -- box had neither. These offsets are read by whichever elements are
            -- using the Shadow outline style, and this page cannot know that.
        end

        -- ===== AFFECTED ELEMENTS GROUP (a 280 box in column 2 in classic, a
        -- full-width box here) =====
        -- STAYS A BOX in both layouts -- see the judgement at the top of the page.
        -- It wears the band skin in the popout arm so it does not read as a second
        -- visual language beside the rows; the classic arm passes no opts at all,
        -- which is what it always did.
        --
        -- ⚠ THE LIST IS MEASURED, NOT PINNED, IN THE WIDE ARM. Its 235 was the
        -- height twelve bullets wrap to AT 250; at the band's width several of
        -- them stop wrapping, so the same number would leave a hole under the
        -- list. CreateLabel measures itself whenever the call site does not pin
        -- it, which is the pet blurbs' rule -- and classic keeps the pinned
        -- number, because classic keeps the width it was measured at.
        --
        -- ⚠ THE NOTE KEEPS ITS 40 in both: one sentence is one line at 250 and
        -- still one line wider, so the slot does not move.
        local INFO_LIST = L["• Text Designer (Name, Health, Status & custom text)\n• Buff Stack & Duration\n• Debuff Stack & Duration\n• Pet Frame Text\n• Targeted Spell Duration\n• Defensive Icon Duration\n• All Icon Text (Res, Summon, etc.)\n• Group Labels (Raid)\n• Targeted List\n• Personal Targeted Spell\n• Aura Designer Indicators\n• Pinned Frames"]
        local INFO_NOTE = L["Font sizes are not changed. Adjust sizes in each element's page."]
        if classicLayout then
            local infoGroup = GUI:CreateSettingsGroup(self.child, 280)
            infoGroup:AddWidget(GUI:CreateHeader(self.child, L["Affected Elements"]), 40)
            infoGroup:AddWidget(GUI:CreateLabel(self.child, INFO_LIST, 250), 235)
            infoGroup:AddWidget(GUI:CreateNote(self.child, INFO_NOTE, {tone = "caution", prefix = "Note", width = 250}), 40)
            Add(infoGroup, nil, 2)
        else
            local infoGroup = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), tools.INLINE_BOX)
            infoGroup:AddWidget(GUI:CreateHeader(self.child, L["Affected Elements"]), 40)
            local infoInner = GUI:GroupInnerWidth(infoGroup)
            infoGroup:AddWidget(GUI:CreateLabel(self.child, INFO_LIST, infoInner))
            infoGroup:AddWidget(GUI:CreateNote(self.child, INFO_NOTE, {tone = "caution", prefix = "Note", width = infoInner}), 40)
            -- ⚠ THE BAND IS ADDED AFTER ITS LAST ROW AND BEFORE THIS BOX. `Add`
            -- resolves a widget's slot height on the spot, so a band added before
            -- its rows would be measured empty. The box follows it because that is
            -- the READING order -- with both of them "both", there is no column
            -- flow left for a sync point to strand.
            Add(fontBand, nil, "both")
            Add(infoGroup, nil, "both")
        end
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

        -- ===== THE PAGE'S TWO LAYOUTS =====================================
        -- CLASSIC is exactly what it always was: four 280 boxes in two columns.
        -- POPOUT turns the three MULTI-CONTROL groups into feature rows -- Raid
        -- Group Labels, Font Settings, Position -- and gives the fourth, which is
        -- one dropdown, a CONTROL ROW: a pane holding one dropdown is a click that
        -- buys nothing, but a 280 box beside a full-width band is the one shape a
        -- column of plates cannot absorb.
        --
        -- Every converted group's widgets live in a `Build<X>Group(tools2)`
        -- taking { group, parent, refreshStates } and, where a toggle is hoisted,
        -- `hoistToggle`. The classic branch mounts the SAME builder into the box
        -- it always built, which is what makes "classic is unchanged" structural
        -- rather than a promise -- test_grouplabels_page_builders.lua pins the
        -- inventory of each one against the census taken before the move.
        local classicLayout = DF:IsClassicSettingsLayout()
        -- The shared page-scope machinery: eager holders, pane reflow, the key
        -- claim, the amber tick, the footer's Reset Group / Hold: Defaults, the
        -- hoisted-toggle search repair and the band width. nil in classic, which
        -- is what every `if classicLayout then` arm below leans on.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ===== THE PAGE'S ONE BAND ========================================
        -- Full-width and chromeless: a feature row's popout docks outside the
        -- WINDOW and runs a beam back to the row, so a row that stopped 280px in
        -- would leave that beam crossing half the page.
        --
        -- ⚠ NO HEADER ON IT. A header names a SECTION, and this page is one
        -- subject end to end -- the first row's own label already says "Raid
        -- Group Labels", so a header above it would say the same thing twice.
        -- That is the Frame page's one-row-band rule generalised: the band earns
        -- a header only when its rows share a word none of them says alone.
        local labelBand
        if tools then
            labelBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
        end

        -- ===== SETTINGS (a 280 box in classic, the band's first row) =======
        -- Once the enable tick is hoisted onto the row this group is a BLURB, and
        -- that is what decides the row's shape below.
        local function BuildLabelSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateLabel(parent, L["Display labels above or beside each raid group."], 250), 25)

            -- Suppressed when the ROW carries this tick. Still built in classic,
            -- where it is the group's only on/off control.
            if not tools2.hoistToggle then
                local groupLabelEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Group Labels"], db, "groupLabelEnabled", function()
                    UpdateLabels()
                    self:RefreshStates()
                end), 30)
                groupLabelEnable.keepEnabled = true
            end
        end

        -- ===== FONT (a 280 box in classic, a band row) =====================
        -- ⚠ THE GROUP GATE STAYS INSIDE THE BUILDER. In classic the box greys its
        -- own children while group labels are off; the pane has to do the same,
        -- and one builder serving both is what stops the two drifting.
        local function BuildFontGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], db, "groupLabelFont", UpdateLabels), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Font Size"], 8, 24, 1, db, "groupLabelFontSize", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)

            group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], db, "groupLabelOutline", UpdateLabels), 55)
            group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], db, "groupLabelOutline", UpdateLabels), 30)
            group:AddWidget(GUI:CreateColorPicker(parent, L["Label Color"], db, "groupLabelColor", true, UpdateLabels, function() DF:LightweightUpdateGroupLabelColor() end, true), 35)
            group.disableChildrenOn = DisableGroupLabelOptions
        end

        -- ===== POSITION (a 280 box in classic, a band row) =================
        local function BuildPositionGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local positionOptions = {
                ["START"] = L["Start of Group"],
                ["CENTER"] = L["Center of Group"],
                ["END"] = L["End of Group"],
            }
            group:AddWidget(GUI:CreateDropdown(parent, L["Label Position"], positionOptions, db, "groupLabelPosition", UpdateLabels), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -100, 100, 1, db, "groupLabelOffsetX", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -100, 100, 1, db, "groupLabelOffsetY", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)
            group:AddWidget(GUI:CreateLabel(parent, L["Start: Above/left of groups.\nCenter: Middle of the group.\nEnd: Below/right of groups."], 250), 50)
            group.disableChildrenOn = DisableGroupLabelOptions
        end

        if classicLayout then
            -- ===== SETTINGS GROUP (Column 1) =====
            local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
            settingsGroup:AddWidget(GUI:CreateHeader(self.child, L["Raid Group Labels"]), 40)
            BuildLabelSettingsGroup({
                group = settingsGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            settingsGroup.hideOn = HideGroupLabelOptions
            Add(settingsGroup, nil, 1)
        end

        -- ===== TEXT FORMAT (a 280 box in column 2 in classic, a control row
        -- here) =====
        local formatOptions = {
            ["GROUP_NUM"] = L["Group 1"],
            ["SHORT"] = L["G1"],
            ["NUM_ONLY"] = L["1"],
            ["ROMAN"] = L["I, II, III..."],
        }

        -- ☠ ONE SETTING IS A CONTROL ROW -- NOT A BOX, AND STILL NOT A POPOUT. A
        -- pane holding one dropdown is a click that buys nothing, so this never
        -- earned a feature row; but a 280 box beside a full-width band is a
        -- narrower rectangle with its own border and its own left edge, in a list
        -- whose whole argument is that every row starts at the same x. So the
        -- dropdown wears the same plate the three rows do
        -- (DandersUI/ControlRow.lua), in a chromeless band of its own.
        --
        -- ⚠ ONE NAME, AND IT IS THE CONTROL'S. "Text Format" named a SECTION; the
        -- row IS the setting, and "Label Format" is what the dropdown has always
        -- been called -- so the entry the kit registers off this label is the SAME
        -- entry classic registers, rather than one setting under two spellings.
        -- (The Self Position row on the Sorting page goes the other way for the
        -- opposite reason: its control's caption is the bare word "Position",
        -- which does not say whose.)
        --
        -- ⚠ NO HEADER ON THE BAND, for the reason the label band above it carries
        -- none: a header naming a section directly above a single row that already
        -- names itself is the page saying it twice.
        --
        -- ⚠ THE db IS THE TABLE, NOT tools.RowDB: only a TABLE binding yields the
        -- dbRef a dropdown needs to reach the override markers and the search
        -- index, and the page is rebuilt on a mode switch anyway. The Language
        -- row's rule (Pages/Options.lua).
        --
        -- ⚠ THE BOX'S TWO GATES, ON THE ROW: hideOn is the ROW's, so the band's
        -- own layout collapses the slot instead of drawing an empty box, and the
        -- group's disableChildrenOn over one child is the row's own disableOn --
        -- which is how the other three rows on this page already say it.
        local formatBand
        if classicLayout then
            local formatGroup = GUI:CreateSettingsGroup(self.child, 280)
            formatGroup:AddWidget(GUI:CreateHeader(self.child, L["Text Format"]), 40)
            formatGroup:AddWidget(GUI:CreateDropdown(self.child, L["Label Format"], formatOptions, db, "groupLabelFormat", UpdateLabels), 55)
            formatGroup.hideOn = HideGroupLabelOptions
            formatGroup.disableChildrenOn = DisableGroupLabelOptions
            Add(formatGroup, nil, 2)
        else
            -- ⚠ CONSTRUCTED HERE, ADDED AT THE FOOT. `Add` resolves a widget's slot
            -- height on the spot, so the label band has to go in AFTER its last row
            -- -- which is why the pair is added together down there, in the order
            -- the page reads.
            formatBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })
            local formatRow = formatBand:AddWidget(GUI:CreateControlRow(self.child, {
                label     = L["Label Format"],
                kind      = "dropdown",
                options   = formatOptions,
                db        = db,
                key       = "groupLabelFormat",
                onChanged = UpdateLabels,
                hideOn    = HideGroupLabelOptions,
            }))
            formatRow.disableOn = DisableGroupLabelOptions
            tools.RegisterControlRow(formatRow, "dropdown", "groupLabelFormat")
        end

        if classicLayout then
            -- ===== FONT GROUP (Column 2) =====
            local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
            fontGroup:AddWidget(GUI:CreateHeader(self.child, L["Font Settings"]), 40)
            BuildFontGroup({
                group = fontGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            fontGroup.hideOn = HideGroupLabelOptions
            Add(fontGroup, nil, 2)

            -- ===== POSITION GROUP (Column 1) =====
            local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
            positionGroup:AddWidget(GUI:CreateHeader(self.child, L["Position"]), 40)
            BuildPositionGroup({
                group = positionGroup,
                parent = self.child,
                refreshStates = function() self:RefreshStates() end,
            })
            positionGroup.hideOn = HideGroupLabelOptions
            Add(positionGroup, nil, 1)
        else
            -- ---- the enable row ------------------------------------------
            -- ☠ NO COUNT, NO FOOTER AND NO MODIFIED TICK on this row, following
            -- the Frame page's Raid Layout Mode precedent. The badge claims how
            -- many CONTROLS are behind the row and behind this one there are none
            -- -- the tick is on the row and what is left is an explanation. A
            -- reset strip is worse than absent for the same reason: it would be
            -- offered over zero claimed keys, so it would say it had reset
            -- something and reset nothing. The other two rows carry both.
            --
            -- ☠ NOT GUI:RefreshCurrentPage, which is what the classic checkbox
            -- would reach for. A rebuild retires every widget on the page
            -- including the row being clicked, and the row's write path calls
            -- row.Refresh() after this returns -- on a dead frame. RefreshStates
            -- re-runs the hideOn and disableOn passes without destroying
            -- anything, and ReflowMounted is what greys the two open panes: their
            -- own disableChildrenOn reads the same key from inside the pane.
            local function OnGroupLabelsToggle()
                UpdateLabels()
                self:RefreshStates()
                tools.ReflowMounted()
            end

            local labelsMount = tools.PopoutContent(function(group, holder, reflow)
                BuildLabelSettingsGroup({
                    group = group, parent = holder,
                    refreshStates = reflow,
                    hoistToggle = true,
                })
            end)
            local labelsRow = labelBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label    = L["Raid Group Labels"],
                db       = tools.RowDB,
                toggle   = { key = "groupLabelEnabled" },
                onToggle = OnGroupLabelsToggle,
                window   = DF.GUIFrame,
                clipTo   = self,
                build    = labelsMount,
            }))
            tools.RegisterHoistedToggle(labelsRow, L["Enable Group Labels"], "groupLabelEnabled", OnGroupLabelsToggle)
            -- The box's own gate, on the row: raid mode and the group-based
            -- layout, or the whole subject is moot. A row carries hideOn the way
            -- any other widget in a settings group does, so the band simply has
            -- fewer rows in party or flat mode.
            labelsRow.hideOn = HideGroupLabelOptions

            -- ---- the font row --------------------------------------------
            -- The summary, per the page convention: at most four items, a fixed
            -- order, " \194\183 " between them, WORDS localised and numbers raw,
            -- every read guarded because a profile mid-migration may be missing
            -- any of these keys.
            --
            -- ⚠ THE FONT NAME IS UNCONDITIONAL, unlike the outline beside it, for
            -- the reason Frame Size prints its dimensions unconditionally: it is
            -- the row's headline, and a Font Settings row that printed nothing on
            -- a default profile would be the one row on the page saying less than
            -- its own label.
            --
            -- The NAME comes from DF:GetFontNameFromPath -- the addon's own
            -- font display-name resolver, and the one CreateFontDropdown itself
            -- prints on its button, so the row and the control behind it cannot
            -- disagree. (The Changed Settings ledger shortens media the same way,
            -- through this function's texture sibling; its own MediaName wrapper
            -- is a file-local there and walks the STATUSBAR list, which is the
            -- wrong list for a font.) Fonts are stored as a NAME already, so on a
            -- current profile this hands back what it was given; the resolver
            -- earns its keep on a legacy profile that stored a path.
            local function FontSettingsSummary(d)
                if not d then return "" end
                local parts = {}
                local fontName = DF.GetFontNameFromPath and DF:GetFontNameFromPath(d.groupLabelFont)
                if type(fontName) == "string" and fontName ~= "" then
                    parts[#parts + 1] = fontName
                end
                local size = tonumber(d.groupLabelFontSize)
                if size then parts[#parts + 1] = format("%d", math.floor(size)) end
                -- The outline WORD, and only when there is one: the shipped
                -- default composes to NONE, so a default profile would otherwise
                -- spend the width saying "None".
                local flag = DF.OutlineFlag and DF:OutlineFlag(d.groupLabelOutline) or nil
                if flag == "OUTLINE" then parts[#parts + 1] = L["Outline"]
                elseif flag == "THICKOUTLINE" then parts[#parts + 1] = L["Thick Outline"]
                elseif flag == "MONOCHROME" then parts[#parts + 1] = L["Monochrome"]
                elseif flag == "MONOCHROME, OUTLINE" then parts[#parts + 1] = L["Monochrome Outline"]
                elseif flag == "MONOCHROME, THICKOUTLINE" then parts[#parts + 1] = L["Monochrome Thick Outline"]
                end
                return table.concat(parts, " \194\183 ")
            end

            -- Five, which is the whole group: nothing is hoisted, because there
            -- is no boolean in here meaning "am I doing anything".
            local FONT_SETTINGS_COUNT = 5

            local fontMount, fontContent = tools.PopoutContent(function(group, holder, reflow)
                BuildFontGroup({ group = group, parent = holder, refreshStates = reflow })
            end)
            local fontRow = labelBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Font Settings"],
                db      = tools.RowDB,
                summary = FontSettingsSummary,
                count   = FONT_SETTINGS_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = fontMount,
            }))
            -- ⚠ THE OUTLINE KEY IS CLAIMED TWICE, and that is the walk working as
            -- designed: the outline dropdown and the shadow tick are two views of
            -- one stored value (groupLabelOutline), so both stamp it. A repeated
            -- key costs the defaults engine one extra lookup and changes no
            -- answer -- neither the tick's "is any of these modified" nor the
            -- reset's write is order- or count-sensitive.
            tools.ClaimKeys(fontRow, fontContent)
            tools.WireModifiedTick(fontRow)
            tools.WireFooter(fontRow, UpdateLabels)
            fontRow.hideOn = HideGroupLabelOptions
            fontRow.disableOn = DisableGroupLabelOptions

            -- ---- the position row ----------------------------------------
            -- The placement word, then the offsets when they are not both zero --
            -- the Border Shadow row's own convention for an offset pair. The
            -- SHORT words, not the dropdown's full phrases: "Start of Group" next
            -- to a pair of numbers reads as a sentence that got cut off, and the
            -- row's own label already supplies "Position".
            local function PositionSummary(d)
                if not d then return "" end
                local parts = {}
                local pos = d.groupLabelPosition
                if pos == "START" then parts[#parts + 1] = L["Start"]
                elseif pos == "CENTER" then parts[#parts + 1] = L["Center"]
                elseif pos == "END" then parts[#parts + 1] = L["End"]
                end
                local ox = tonumber(d.groupLabelOffsetX) or 0
                local oy = tonumber(d.groupLabelOffsetY) or 0
                if ox ~= 0 or oy ~= 0 then
                    parts[#parts + 1] = format("%d, %d", math.floor(ox), math.floor(oy))
                end
                return table.concat(parts, " \194\183 ")
            end

            -- Four: the dropdown, the two offsets and the explainer under them.
            local POSITION_COUNT = 4

            local posMount, posContent = tools.PopoutContent(function(group, holder, reflow)
                BuildPositionGroup({ group = group, parent = holder, refreshStates = reflow })
            end)
            local positionRow = labelBand:AddWidget(GUI:CreatePopoutRow(self.child, {
                label   = L["Position"],
                db      = tools.RowDB,
                summary = PositionSummary,
                count   = POSITION_COUNT,
                window  = DF.GUIFrame,
                clipTo  = self,
                build   = posMount,
            }))
            tools.ClaimKeys(positionRow, posContent)
            tools.WireModifiedTick(positionRow)
            tools.WireFooter(positionRow, UpdateLabels)
            positionRow.hideOn = HideGroupLabelOptions
            positionRow.disableOn = DisableGroupLabelOptions

            -- The band, then the Text Format row's own band -- see the note up at
            -- Text Format for why the pair is added here rather than in place.
            -- Both are "both", so the order below is purely reading order.
            Add(labelBand, nil, "both")
            Add(formatBand, nil, "both")
        end

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
        local HIGHLIGHT_MAX_SETS = (DF.PinnedFrames and DF.PinnedFrames.MAX_SETS) or 4
        
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

        -- ☠ RE-CLAMP ON EVERY CALL, not just at page build. The build-time clamp above
        -- (see `persistedTab`) already knew the index could address a set that is gone
        -- "or in the other mode" -- but it runs ONCE, when the page is constructed, and
        -- a mode switch does not rebuild the page: it drives the REFRESH path. Joining a
        -- raid while the party side had more pinned sets than the raid side therefore
        -- left `activeHighlightTab` pointing past the end of the live list, and the ~27
        -- call sites that index this directly threw "attempt to index a nil value" --
        -- nine at once, one per refreshed control (Aphoex, 5.2.0-alpha.1, on entering a
        -- raid; stack came in through the roster widget's getter).
        -- ⚠ The clamp is the FIX; the nil return is only the last resort. RemoveSet
        -- refuses to drop below one set, so an empty list is unreachable by design and a
        -- nil here means something else is wrong -- callers that write must NOT silently
        -- swallow that, which is why this does not hand back a scratch table.
        local function GetCurrentSet()
            local sets = db.pinnedFrames and db.pinnedFrames.sets
            if type(sets) ~= "table" then return nil end
            local n = #sets
            if n == 0 then return nil end
            if activeHighlightTab > n then activeHighlightTab = n end
            if activeHighlightTab < 1 then activeHighlightTab = 1 end
            -- Keep the persisted value honest too, or the next page build re-reads the
            -- stale index and the clamp has to happen all over again.
            pagePinnedFrames.persistedTab = activeHighlightTab
            return sets[activeHighlightTab]
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
                -- ☠ DIRECTION IS PART OF THE REBUILD KEY, NOT JUST FRAME TYPE. The arrange
                -- controls bake orientation into their LABELS via pinVert, and a label is
                -- fixed at build time -- RefreshControls only refreshes values. Gating on
                -- frameType alone left two same-type sets of opposite direction showing
                -- each other's edge names. Mirrors OnPinnedDirectionChanged, which already
                -- rebuilds the whole page when this key changes on the current set.
                local oldDir = oldSet and oldSet.growDirection
                activeHighlightTab = i
                pagePinnedFrames.persistedTab = i
                local newSet = GetCurrentSet()
                local newType = newSet and newSet.frameType
                local newDir = newSet and newSet.growDirection
                RefreshTabs()
                if (oldType ~= newType or oldDir ~= newDir) and GUI.RefreshCurrentPage then
                    -- Frame type or direction differs between tabs — invalidate cache so the
                    -- page rebuilds with the correct widgets and labels for the new set.
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
            -- ☠ Must be gated on IsEditingActiveMode, exactly like the Enable and
            -- Show Label siblings above. SetEnabled resolves its target through
            -- GetSetDB -> GetPinnedModeDB, which picks the mode from IsInRaid() --
            -- NOT from the mode being edited -- and it PERSISTS (set.enabled = ...).
            -- Without the guard, ticking this while in a raid but editing Party
            -- wrote the party set's enabled value over the RAID set's and saved it,
            -- so a raid pinned header could pop on mid-raid or silently vanish.
            if IsEditingActiveMode() then
                DF.PinnedFrames:SetEnabled(activeHighlightTab, GetCurrentSet().enabled)
            end
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
        end, L["Removes this set's pinned members from your main party/raid frames so they appear only in the pinned set. Applies out of combat. Your frame sorting setting is preserved."]), 28)
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
        nameInputContainer.Refresh = function()
            local s = GetCurrentSet()
            nameInput:SetText((s and s.name) or "")
        end
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
        -- GUI.Space.section IS 10; this was the same value written out by hand. The
        -- other stray AddSpace literals (5, 6, 8, 18) match no constant, so converting
        -- those would MOVE things rather than tidy them — left alone deliberately.
        AddSpace(GUI.Space.section, "both")

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

        -- ☠ SAME TWO PERPENDICULAR AXES AS THE RAID PAGE, read off THIS SET'S OWN
        -- growDirection -- pinned direction is per-set and NOT inherited (the main frames'
        -- growDirection means group Rows/Columns, a different concept).
        --   MAIN  = frameAnchor,  the direction frames flow. HORIZONTAL -> Left/Right
        --   CROSS = columnAnchor, where they wrap.           HORIZONTAL -> Top/Bottom
        -- Verified against PinnedFrames.lua (the anchor-corner build and the slot offsets),
        -- not against the control names: horizontal puts frameAnchor on X and columnAnchor
        -- on Y, vertical swaps them.
        local pinnedSet = GetCurrentSet()
        local pinVert = (pinnedSet and pinnedSet.growDirection or "HORIZONTAL") == "VERTICAL"
        local PIN_MAIN_START  = pinVert and L["Top"]  or L["Left"]
        local PIN_MAIN_END    = pinVert and L["Bottom"] or L["Right"]
        local PIN_CROSS_START = pinVert and L["Left"] or L["Top"]
        local PIN_CROSS_END   = pinVert and L["Right"] or L["Bottom"]

        -- ☠ THE DIRECTION DROPDOWN MUST REBUILD THE PAGE. Every label and value below is
        -- baked from pinVert at build time, and UpdateHighlightLayout only re-lays the
        -- frames -- the widgets' own .Refresh re-reads the set's VALUE, never its option
        -- table. Without the rebuild, flipping Direction leaves two dropdowns offering the
        -- previous orientation's edges and two labels naming the wrong axis until the page
        -- is reopened. Safe to rebuild: activeHighlightTab round-trips through
        -- pagePinnedFrames.persistedTab, so the edited set survives. Deferred so it runs
        -- after the triggering dropdown's own click handler has unwound, matching the raid
        -- page's OnGrowthDirectionChanged.
        local function OnPinnedDirectionChanged()
            UpdateHighlightLayout()
            C_Timer.After(0, function()
                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            end)
        end

        -- ☠ _order, or CreateDropdown sorts on the DISPLAY TEXT -- see the note beside the
        -- raid page's growOptions. A Top/Bottom pair without it lists as "Bottom, Top".
        local directionOptions = { _order = { "HORIZONTAL", "VERTICAL" }, HORIZONTAL= L["Horizontal"], VERTICAL= L["Vertical"] }
        arrangeGroup:AddWidget(CreateRefreshableDropdown(self.child, L["Direction"], directionOptions, "growDirection", OnPinnedDirectionChanged), 55)

        -- CENTER intentionally omitted: it isn't truly implemented for pinned
        -- frames (frames grow START-style; only the anchor/label shift). START/END
        -- only for now; a real centred layout can be added later.
        local frameAnchorOptions = { _order = { "START", "END" }, START= PIN_MAIN_START, END= PIN_MAIN_END }
        arrangeGroup:AddWidget(CreateRefreshableDropdown(self.child, L["Frames Grow From"], frameAnchorOptions, "frameAnchor", UpdateHighlightLayout), 55)

        -- CROSS axis, so the label follows the orientation too: horizontal frames wrap into
        -- new ROWS, vertical ones into new COLUMNS. This read "Columns Grow From" whatever
        -- the direction was, which is right in only one of the two.
        local columnAnchorLabel = pinVert and L["Columns Grow From"] or L["Rows Grow From"]
        local columnAnchorOptions = { _order = { "START", "END" }, START= PIN_CROSS_START, END= PIN_CROSS_END }
        arrangeGroup:AddWidget(CreateRefreshableDropdown(self.child, columnAnchorLabel, columnAnchorOptions, "columnAnchor", UpdateHighlightLayout), 55)

        local unitsPerLabel = pinVert and L["Units Per Column"] or L["Units Per Row"]
        arrangeGroup:AddWidget(CreateRefreshableSlider(self.child, unitsPerLabel, 1, 10, 1, "unitsPerRow", UpdateHighlightLayout), 55)
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
            -- Guarded as well as clamped: this is the getter the raid-join crash came
            -- through, and a roster with no set to read is an empty roster, not an error.
            function() local s = GetCurrentSet() return s and s.players or {} end,
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

        -- ☠ ALL FOUR AUTO-POPULATE HANDLERS NEED IsEditingActiveMode.
        -- AutoPopulateSet reads the LIVE roster (`local isRaid = IsInRaid()`, then raidN /
        -- partyN tokens) and writes the names it finds into GetCurrentSet() -- which is the
        -- set for the mode being EDITED, not the mode you are in. So sitting in a 20-man
        -- raid, switching the mode selector to Party to tidy the party set, and ticking
        -- "Auto-add Healers" wrote five raid healers' names into the PARTY set and saved it.
        --
        -- The Enable / Show Label / Show in Solo Mode siblings ~500 lines above are all
        -- gated on IsEditingActiveMode, and the solo one carries a note describing this
        -- exact failure in the other direction. These four were missed.
        --
        -- The checkbox VALUE still saves either way (that is just config); only the live
        -- roster scrape is suppressed when you are editing the mode you are not in.
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Auto-add Tanks"], "autoAddTanks", function()
            if IsEditingActiveMode() and GetCurrentSet().autoAddTanks and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
                SyncPlayersOverride()
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Auto-add Healers"], "autoAddHealers", function()
            if IsEditingActiveMode() and GetCurrentSet().autoAddHealers and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
                SyncPlayersOverride()
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Auto-add DPS"], "autoAddDPS", function()
            if IsEditingActiveMode() and GetCurrentSet().autoAddDPS and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
                SyncPlayersOverride()
            end
        end), 28)
        -- Exclude Self: keep the player out of this set's auto-add (e.g. Aug Evoker
        -- who buffs others). Re-runs auto-populate so self is added/removed live.
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Exclude Self"], "excludeSelf", function()
            if IsEditingActiveMode() and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
                SyncPlayersOverride()
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, L["Keep when offline/left"], "keepOfflinePlayers", function() end, L["Players you add yourself (drag, the role buttons, or Add Offline Player) always stay pinned. This only affects members added automatically by role: leave it on to keep them after they go offline or leave the group, or off to drop them from the set."]), 28)

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
