-- Part 5 of the settings pages, split from Options.lua.
-- The parts run as a chain so the pages build in their original order.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local format = string.format
function DF._SetupGUIPagesPart5(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
    BuildPage(pageIcons, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        -- Every icon on the page needs its own prefix; "combatIcon" was the one
        -- omission, so the Combat icon's seven settings were skipped by Copy, Sync
        -- and Reset while every other icon on the same page travelled.
        Add(CreateCopyButton(self.child, {"roleIcon", "leaderIcon", "raidTargetIcon", "readyCheckIcon", "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon", "vehicleIcon", "raidRoleIcon", "bgCarrierIcon", "combatIcon", "statusIconFont", "statusIconFontSize", "statusIconFontOutline"}, L["Icons"], "indicators_icons"), 25, 2)
        
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
        local textSection = Add(GUI:CreateCollapsibleSection(self.child, L["Icon Text Settings"], false, 280), 36, 1)
        
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
        local roleSection = Add(GUI:CreateCollapsibleSection(self.child, L["Role Icon"], false, 280), 36, 1)

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

        -- Settings
        local roleSettings = GUI:CreateSettingsGroup(self.child, 280)
        roleSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
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
        local roleAppearance = GUI:CreateSettingsGroup(self.child, 280)
        roleAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        roleAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "roleIconScale", nil, function() DF:LightweightUpdateIconPosition("role") end, true), 55)
        roleAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "roleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("role") end, true), 55)
        roleAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "roleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("role") end, true)), 55)
        roleAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide In Combat"], db, "roleIconHideInCombat", function() DF:UpdateAllRoleIcons() end), 30)
        Add(roleAppearance, nil, 1)
        roleSection:RegisterChild(roleAppearance)

        -- Position
        local rolePosition = GUI:CreateSettingsGroup(self.child, 280)
        rolePosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
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
        local leaderSection = Add(GUI:CreateCollapsibleSection(self.child, L["Leader Icon"], false, 280), 36, 1)
        WireStatusPreview(leaderSection, { enableKey = "leaderIconEnabled", icons = { "Interface\\GroupFrame\\UI-Group-LeaderIcon" } })
        
        -- Settings
        local leaderSettings = GUI:CreateSettingsGroup(self.child, 280)
        leaderSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
        leaderSettings.disableChildrenOn = function(d) return not d.leaderIconEnabled end
        local leaderIconEnableCb = leaderSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Leader Icon"], db, "leaderIconEnabled", function() DF:UpdateAllFrames() end), 30)
        leaderIconEnableCb.keepEnabled = true
        Add(leaderSettings, nil, 1)
        leaderSection:RegisterChild(leaderSettings)

        -- Appearance
        local leaderAppearance = GUI:CreateSettingsGroup(self.child, 280)
        leaderAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        leaderAppearance.disableChildrenOn = function(d) return not d.leaderIconEnabled end
        leaderAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "leaderIconScale", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55)
        leaderAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "leaderIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("leader") end, true), 55)
        leaderAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "leaderIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("leader") end, true)), 55)
        leaderAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "leaderIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(leaderAppearance, nil, 1)
        leaderSection:RegisterChild(leaderAppearance)

        -- Position
        local leaderPosition = GUI:CreateSettingsGroup(self.child, 280)
        leaderPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        leaderPosition.disableChildrenOn = function(d) return not d.leaderIconEnabled end
        leaderPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "leaderIconAnchor", function() DF:LightweightUpdateIconPosition("leader") end), 55)
        leaderPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "leaderIconX", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55)
        leaderPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "leaderIconY", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55)
        Add(leaderPosition, nil, 1)
        leaderSection:RegisterChild(leaderPosition)
        
        -- ============================================
        -- RAID TARGET ICON (Collapsible)
        -- ============================================
        local raidTargetSection = Add(GUI:CreateCollapsibleSection(self.child, L["Target Marker Icon"], false, 280), 36, 1)
        -- Header preview: the four most-used markers (square / cross / triangle / circle),
        -- sliced from the classic raid-target sheet via texcoords (the atlas form won't render here).
        WireStatusPreview(raidTargetSection, { enableKey = "raidTargetIconEnabled", icons = {
            { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.25, 0.5,  0.25, 0.5  }, inset = 2 },  -- square   (6)
            { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.5,  0.75, 0.25, 0.5  }, inset = 2 },  -- cross    (7)
            { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.75, 1.0,  0.0,  0.25 }, inset = 2 },  -- triangle (4)
            { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.25, 0.5,  0.0,  0.25 }, inset = 2 },  -- circle   (2)
        } })
        
        -- Settings
        local rtSettings = GUI:CreateSettingsGroup(self.child, 280)
        rtSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
        rtSettings.disableChildrenOn = function(d) return not d.raidTargetIconEnabled end
        local raidTargetIconEnableCb = rtSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Target Marker Icon"], db, "raidTargetIconEnabled", function() DF:UpdateAllFrames() end), 30)
        raidTargetIconEnableCb.keepEnabled = true
        Add(rtSettings, nil, 1)
        raidTargetSection:RegisterChild(rtSettings)

        -- Appearance
        local rtAppearance = GUI:CreateSettingsGroup(self.child, 280)
        rtAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        rtAppearance.disableChildrenOn = function(d) return not d.raidTargetIconEnabled end
        rtAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "raidTargetIconScale", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55)
        rtAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "raidTargetIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("raidTarget") end, true), 55)
        rtAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "raidTargetIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("raidTarget") end, true)), 55)
        rtAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "raidTargetIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(rtAppearance, nil, 1)
        raidTargetSection:RegisterChild(rtAppearance)

        -- Position
        local rtPosition = GUI:CreateSettingsGroup(self.child, 280)
        rtPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        rtPosition.disableChildrenOn = function(d) return not d.raidTargetIconEnabled end
        rtPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "raidTargetIconAnchor", function() DF:LightweightUpdateIconPosition("raidTarget") end), 55)
        rtPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "raidTargetIconX", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55)
        rtPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "raidTargetIconY", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55)
        Add(rtPosition, nil, 1)
        raidTargetSection:RegisterChild(rtPosition)
        
        -- ============================================
        -- READY CHECK ICON (Collapsible)
        -- ============================================
        local readySection = Add(GUI:CreateCollapsibleSection(self.child, L["Ready Check Icon"], false, 280), 36, 1)
        WireStatusPreview(readySection, { enableKey = "readyCheckIconEnabled", icons = { "UI-LFG-ReadyMark-Raid" } })
        
        -- Settings
        local rcSettings = GUI:CreateSettingsGroup(self.child, 280)
        rcSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
        rcSettings.disableChildrenOn = function(d) return not d.readyCheckIconEnabled end
        local readyCheckIconEnableCb = rcSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Ready Check Icon"], db, "readyCheckIconEnabled", function() DF:UpdateAllFrames() end), 30)
        readyCheckIconEnableCb.keepEnabled = true
        rcSettings:AddWidget(GUI:CreateSlider(self.child, L["Persist (seconds)"], 0, 15, 1, db, "readyCheckIconPersist"), 55)
        Add(rcSettings, nil, 1)
        readySection:RegisterChild(rcSettings)

        -- Appearance
        local rcAppearance = GUI:CreateSettingsGroup(self.child, 280)
        rcAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        rcAppearance.disableChildrenOn = function(d) return not d.readyCheckIconEnabled end
        rcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "readyCheckIconScale", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55)
        rcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "readyCheckIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("readyCheck") end, true), 55)
        rcAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "readyCheckIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("readyCheck") end, true)), 55)
        rcAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "readyCheckIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(rcAppearance, nil, 1)
        readySection:RegisterChild(rcAppearance)

        -- Position
        local rcPosition = GUI:CreateSettingsGroup(self.child, 280)
        rcPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        rcPosition.disableChildrenOn = function(d) return not d.readyCheckIconEnabled end
        rcPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "readyCheckIconAnchor", function() DF:LightweightUpdateIconPosition("readyCheck") end), 55)
        rcPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "readyCheckIconX", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55)
        rcPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "readyCheckIconY", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55)
        Add(rcPosition, nil, 1)
        readySection:RegisterChild(rcPosition)
        
        -- ============================================
        -- SUMMON ICON (Collapsible)
        -- ============================================
        local summonSection = Add(GUI:CreateCollapsibleSection(self.child, L["Summon Icon"], false, 280), 36, 1)
        WireStatusPreview(summonSection, { enableKey = "summonIconEnabled", showTextKey = "summonIconShowText", icons = { "RaidFrame-Icon-SummonPending" }, texts = { "summonIconTextPending" } })
        
        -- Settings
        local sumSettings = GUI:CreateSettingsGroup(self.child, 280)
        sumSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
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
        local sumAppearance = GUI:CreateSettingsGroup(self.child, 280)
        sumAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        sumAppearance.disableChildrenOn = function(d) return not d.summonIconEnabled end
        sumAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "summonIconScale", nil, function() DF:LightweightUpdateIconPosition("summon") end, true), 55)
        sumAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "summonIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("summon") end, true), 55)
        sumAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "summonIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("summon") end, true)), 55)
        sumAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "summonIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(sumAppearance, nil, 1)
        summonSection:RegisterChild(sumAppearance)

        -- Position
        local sumPosition = GUI:CreateSettingsGroup(self.child, 280)
        sumPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
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
        local bgCarrierSection = Add(GUI:CreateCollapsibleSection(self.child, L["BG Carrier Icon"], false, 280), 36, 1)
        WireStatusPreview(bgCarrierSection, { enableKey = "bgCarrierIconEnabled", showTextKey = "bgCarrierIconShowText", icons = { "Interface\\Icons\\inv_bannerpvp_02" }, texts = { "bgCarrierIconText" } })

        -- Settings
        local bgcSettings = GUI:CreateSettingsGroup(self.child, 280)
        bgcSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
        bgcSettings.disableChildrenOn = function(d) return not d.bgCarrierIconEnabled end
        local bgCarrierIconEnableCb = bgcSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable BG Carrier Icon"], db, "bgCarrierIconEnabled", function() DF:UpdateAllFrames() end), 30)
        bgCarrierIconEnableCb.keepEnabled = true
        bgcSettings:AddWidget(GUI:CreateLabel(self.child, L["Shows on a friendly party/raid member carrying a battleground objective (flag, orb). Only active inside battlegrounds."], 240), 44)
        bgcSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "bgCarrierIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        bgcSettings:AddWidget(GUI:CreateEditBox(self.child, L["Carrier Text"], db, "bgCarrierIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        Add(bgcSettings, nil, 1)
        bgCarrierSection:RegisterChild(bgcSettings)

        -- Appearance
        local bgcAppearance = GUI:CreateSettingsGroup(self.child, 280)
        bgcAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        bgcAppearance.disableChildrenOn = function(d) return not d.bgCarrierIconEnabled end
        bgcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "bgCarrierIconScale", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        bgcAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "bgCarrierIconAlpha", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        bgcAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "bgCarrierIconFrameLevel", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true)), 55)
        Add(bgcAppearance, nil, 1)
        bgCarrierSection:RegisterChild(bgcAppearance)

        -- Position
        local bgcPosition = GUI:CreateSettingsGroup(self.child, 280)
        bgcPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        bgcPosition.disableChildrenOn = function(d) return not d.bgCarrierIconEnabled end
        bgcPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "bgCarrierIconAnchor", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 55)
        bgcPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "bgCarrierIconX", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        bgcPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "bgCarrierIconY", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        Add(bgcPosition, nil, 1)
        bgCarrierSection:RegisterChild(bgcPosition)

        -- ============================================
        -- COMBAT ICON (Collapsible)
        -- ============================================
        local combatSection = Add(GUI:CreateCollapsibleSection(self.child, L["Combat Icon"], false, 280), 36, 1)
        -- Preview the swords quadrant of the UI-StateIcon sheet (texcoord slice); also
        -- greys the section header when the icon is disabled.
        WireStatusPreview(combatSection, { enableKey = "combatIconEnabled", icons = { { texture = "Interface\\CharacterFrame\\UI-StateIcon", coords = {0.5, 1.0, 0, 0.49} } } })

        -- Settings
        local combatSettings = GUI:CreateSettingsGroup(self.child, 280)
        combatSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
        combatSettings.disableChildrenOn = function(d) return not d.combatIconEnabled end
        local combatIconEnableCb = combatSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Combat Icon"], db, "combatIconEnabled", function() DF:UpdateAllFrames() end), 30)
        combatIconEnableCb.keepEnabled = true
        combatSettings:AddWidget(GUI:CreateLabel(self.child, L["Shows crossed swords on a party/raid member who is in combat."], 240), 44)
        Add(combatSettings, nil, 1)
        combatSection:RegisterChild(combatSettings)

        -- Appearance
        local combatAppearance = GUI:CreateSettingsGroup(self.child, 280)
        combatAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        combatAppearance.disableChildrenOn = function(d) return not d.combatIconEnabled end
        combatAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "combatIconScale", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        combatAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "combatIconAlpha", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        combatAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "combatIconFrameLevel", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true)), 55)
        Add(combatAppearance, nil, 1)
        combatSection:RegisterChild(combatAppearance)

        -- Position
        local combatPosition = GUI:CreateSettingsGroup(self.child, 280)
        combatPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        combatPosition.disableChildrenOn = function(d) return not d.combatIconEnabled end
        combatPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "combatIconAnchor", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 55)
        combatPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "combatIconX", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        combatPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "combatIconY", nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55)
        Add(combatPosition, nil, 1)
        combatSection:RegisterChild(combatPosition)

        -- ============================================
        -- RESURRECTION ICON (Collapsible)
        -- ============================================
        local resSection = Add(GUI:CreateCollapsibleSection(self.child, L["Resurrection Icon"], false, 280), 36, 1)
        WireStatusPreview(resSection, { enableKey = "resurrectionIconEnabled", showTextKey = "resurrectionIconShowText", icons = { "RaidFrame-Icon-Rez" }, texts = { "resurrectionIconTextCasting" } })
        
        -- Settings
        local resSettings = GUI:CreateSettingsGroup(self.child, 280)
        resSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
        resSettings.disableChildrenOn = function(d) return not d.resurrectionIconEnabled end
        local resurrectionIconEnableCb = resSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Resurrection Icon"], db, "resurrectionIconEnabled", function() DF:UpdateAllFrames() end), 30)
        resurrectionIconEnableCb.keepEnabled = true
        resSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "resurrectionIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        resSettings:AddWidget(GUI:CreateEditBox(self.child, L["Casting Text"], db, "resurrectionIconTextCasting", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        -- ("Pending Text" removed: resurrectionIconTextPending was never read by
        -- any render path — live or test — since inception. The pending state
        -- renders as the yellow icon tint.)
        Add(resSettings, nil, 1)
        resSection:RegisterChild(resSettings)

        -- Appearance
        local resAppearance = GUI:CreateSettingsGroup(self.child, 280)
        resAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        resAppearance.disableChildrenOn = function(d) return not d.resurrectionIconEnabled end
        resAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "resurrectionIconScale", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55)
        resAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "resurrectionIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("resurrection") end, true), 55)
        resAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "resurrectionIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("resurrection") end, true)), 55)
        Add(resAppearance, nil, 1)
        resSection:RegisterChild(resAppearance)

        -- Position
        local resPosition = GUI:CreateSettingsGroup(self.child, 280)
        resPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        resPosition.disableChildrenOn = function(d) return not d.resurrectionIconEnabled end
        resPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "resurrectionIconAnchor", function() DF:LightweightUpdateIconPosition("resurrection") end), 55)
        resPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "resurrectionIconX", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55)
        resPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "resurrectionIconY", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55)
        Add(resPosition, nil, 1)
        resSection:RegisterChild(resPosition)
        
        -- ============================================
        -- PHASED ICON (Collapsible)
        -- ============================================
        local phasedSection = Add(GUI:CreateCollapsibleSection(self.child, L["Phased Icon"], false, 280), 36, 1)
        WireStatusPreview(phasedSection, { enableKey = "phasedIconEnabled", showTextKey = "phasedIconShowText", icons = { "RaidFrame-Icon-Phasing" }, texts = { "phasedIconText" } })
        
        -- Settings
        local phSettings = GUI:CreateSettingsGroup(self.child, 280)
        phSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
        phSettings.disableChildrenOn = function(d) return not d.phasedIconEnabled end
        local phasedIconEnableCb = phSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Phased Icon"], db, "phasedIconEnabled", function() DF:UpdateAllFrames() end), 30)
        phasedIconEnableCb.keepEnabled = true
        phSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "phasedIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        phSettings:AddWidget(GUI:CreateEditBox(self.child, L["Status Text"], db, "phasedIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        phSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show LFG Eye for Cross-Instance"], db, "phasedIconShowLFGEye", function() DF:UpdateAllFrames() end), 30)
        Add(phSettings, nil, 1)
        phasedSection:RegisterChild(phSettings)

        -- Appearance
        local phAppearance = GUI:CreateSettingsGroup(self.child, 280)
        phAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        phAppearance.disableChildrenOn = function(d) return not d.phasedIconEnabled end
        phAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "phasedIconScale", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55)
        phAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "phasedIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("phased") end, true), 55)
        phAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "phasedIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("phased") end, true)), 55)
        phAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "phasedIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(phAppearance, nil, 1)
        phasedSection:RegisterChild(phAppearance)

        -- Position
        local phPosition = GUI:CreateSettingsGroup(self.child, 280)
        phPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        phPosition.disableChildrenOn = function(d) return not d.phasedIconEnabled end
        phPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "phasedIconAnchor", function() DF:LightweightUpdateIconPosition("phased") end), 55)
        phPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "phasedIconX", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55)
        phPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "phasedIconY", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55)
        Add(phPosition, nil, 1)
        phasedSection:RegisterChild(phPosition)
        
        -- ============================================
        -- AFK ICON (Collapsible)
        -- ============================================
        local afkSection = Add(GUI:CreateCollapsibleSection(self.child, L["AFK Icon"], false, 280), 36, 1)
        WireStatusPreview(afkSection, { enableKey = "afkIconEnabled", showTextKey = "afkIconShowText", icons = { "characterupdate_clock-icon" }, texts = { "afkIconText" } })
        
        -- AFK is the one icon with a fourth box (Timer Text) on top of the
        -- standard Settings / Appearance / Position trio.
        local afkTimerCB = function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end

        -- Settings
        local afkSettings = GUI:CreateSettingsGroup(self.child, 280)
        afkSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
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
        local afkTimerGroup = GUI:CreateSettingsGroup(self.child, 280)
        afkTimerGroup:AddWidget(GUI:CreateHeader(self.child, L["Timer Text"]), GUI.RowHeight.sectionHeader)
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
        local afkAppearance = GUI:CreateSettingsGroup(self.child, 280)
        afkAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        afkAppearance.disableChildrenOn = function(d) return not d.afkIconEnabled end
        afkAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "afkIconScale", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55)
        afkAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "afkIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("afk") end, true), 55)
        afkAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "afkIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("afk") end, true)), 55)
        afkAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "afkIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(afkAppearance, nil, 1)
        afkSection:RegisterChild(afkAppearance)

        -- Position
        local afkPosition = GUI:CreateSettingsGroup(self.child, 280)
        afkPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        afkPosition.disableChildrenOn = function(d) return not d.afkIconEnabled end
        afkPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "afkIconAnchor", function() DF:LightweightUpdateIconPosition("afk") end), 55)
        afkPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "afkIconX", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55)
        afkPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "afkIconY", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55)
        Add(afkPosition, nil, 1)
        afkSection:RegisterChild(afkPosition)
        
        -- ============================================
        -- VEHICLE ICON (Collapsible)
        -- ============================================
        local vehSection = Add(GUI:CreateCollapsibleSection(self.child, L["Vehicle Icon"], false, 280), 36, 1)
        WireStatusPreview(vehSection, { enableKey = "vehicleIconEnabled", showTextKey = "vehicleIconShowText", icons = { "RaidFrame-Icon-Vehicle" }, texts = { "vehicleIconText" } })
        
        -- Settings
        local vehSettings = GUI:CreateSettingsGroup(self.child, 280)
        vehSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
        vehSettings.disableChildrenOn = function(d) return not d.vehicleIconEnabled end
        local vehicleIconEnableCb = vehSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Vehicle Icon"], db, "vehicleIconEnabled", function() DF:UpdateAllFrames() end), 30)
        vehicleIconEnableCb.keepEnabled = true
        vehSettings:AddWidget(GUI:CreateCheckbox(self.child, L["Show as Text"], db, "vehicleIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30)
        vehSettings:AddWidget(GUI:CreateEditBox(self.child, L["Status Text"], db, "vehicleIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55)
        Add(vehSettings, nil, 1)
        vehSection:RegisterChild(vehSettings)

        -- Appearance
        local vehAppearance = GUI:CreateSettingsGroup(self.child, 280)
        vehAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        vehAppearance.disableChildrenOn = function(d) return not d.vehicleIconEnabled end
        vehAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "vehicleIconScale", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55)
        vehAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "vehicleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("vehicle") end, true), 55)
        vehAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "vehicleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("vehicle") end, true)), 55)
        vehAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "vehicleIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(vehAppearance, nil, 1)
        vehSection:RegisterChild(vehAppearance)

        -- Position
        local vehPosition = GUI:CreateSettingsGroup(self.child, 280)
        vehPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
        vehPosition.disableChildrenOn = function(d) return not d.vehicleIconEnabled end
        vehPosition:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], anchorOptions, db, "vehicleIconAnchor", function() DF:LightweightUpdateIconPosition("vehicle") end), 55)
        vehPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "vehicleIconX", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55)
        vehPosition:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "vehicleIconY", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55)
        Add(vehPosition, nil, 1)
        vehSection:RegisterChild(vehPosition)
        
        -- ============================================
        -- RAID ROLE ICON (Collapsible)
        -- ============================================
        local rrSection = Add(GUI:CreateCollapsibleSection(self.child, L["Raid Role Icon (MT/MA)"], false, 280), 36, 1)
        WireStatusPreview(rrSection, { enableKey = "raidRoleIconEnabled", showTextKey = "raidRoleIconShowText", icons = { "RaidFrame-Icon-MainTank", "RaidFrame-Icon-MainAssist" }, texts = { "raidRoleIconTextTank", "raidRoleIconTextAssist" } })
        
        -- Settings
        local rrSettings = GUI:CreateSettingsGroup(self.child, 280)
        rrSettings:AddWidget(GUI:CreateHeader(self.child, L["Settings"]), GUI.RowHeight.sectionHeader)
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
        local rrAppearance = GUI:CreateSettingsGroup(self.child, 280)
        rrAppearance:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), GUI.RowHeight.sectionHeader)
        rrAppearance.disableChildrenOn = function(d) return not d.raidRoleIconEnabled end
        rrAppearance:AddWidget(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.5, 0.1, db, "raidRoleIconScale", nil, function() DF:LightweightUpdateIconPosition("raidRole") end, true), 55)
        rrAppearance:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "raidRoleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("raidRole") end, true), 55)
        rrAppearance:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "raidRoleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("raidRole") end, true)), 55)
        rrAppearance:AddWidget(GUI:CreateCheckbox(self.child, L["Hide in Combat"], db, "raidRoleIconHideInCombat", function() DF:UpdateAllFrames() end), 30)
        Add(rrAppearance, nil, 1)
        rrSection:RegisterChild(rrAppearance)

        -- Position
        local rrPosition = GUI:CreateSettingsGroup(self.child, 280)
        rrPosition:AddWidget(GUI:CreateHeader(self.child, L["Position"]), GUI.RowHeight.sectionHeader)
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

        -- All three highlights are the same Thickness / Inset / Alpha trio, so the
        -- Inset explanation is written once. Thickness and Alpha get nothing —
        -- they say what they are; Inset is the one that reads as jargon, and here
        -- the label is a bare "Inset" with not even "Border" in front of it.
        local TIP_HL_INSET = L["How far inside the frame edge the highlight sits. Negative values push it outward, so it rings the frame instead of hugging it — useful when the highlight would otherwise sit under auras or text."]
        
        -- ========================================
        -- SELECTION HIGHLIGHT SECTION
        -- ========================================
        local selectionSection = Add(GUI:CreateCollapsibleSection(self.child, L["Selection Highlight"], true), 36, "both")
        currentSection = selectionSection
        
        local function HideSelectionOptions(d) return d.selectionHighlightMode == "NONE" end
        
        local selGroup = GUI:CreateSettingsGroup(self.child, 280)
        selGroup:AddWidget(GUI:CreateHeader(self.child, L["Selection Settings"]), 40)
        selGroup:AddWidget(GUI:CreateDropdown(self.child, L["Mode"], highlightModes, db, "selectionHighlightMode", function()
            self:RefreshStates()
        end), 55)
        local selThick = selGroup:AddWidget(GUI:CreateSlider(self.child, L["Thickness"], 1, 10, 1, db, "selectionHighlightThickness", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selThick.hideOn = HideSelectionOptions
        local selInset = selGroup:AddWidget(GUI:CreateSlider(self.child, L["Inset"], -10, 10, 1, db, "selectionHighlightInset", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selInset.hideOn = HideSelectionOptions
        selInset.tooltip = TIP_HL_INSET
        local selAlpha = selGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "selectionHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selAlpha.hideOn = HideSelectionOptions
        local selCol = selGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "selectionHighlightColor", false, nil, function() DF:LightweightUpdateSelectionHighlightColor() end, true), 35)
        selCol.hideOn = HideSelectionOptions
        AddToSection(selGroup, nil, 1)
        
        currentSection = nil
        AddSpace(GUI.Space.section, "both")
        
        -- ========================================
        -- HOVER HIGHLIGHT SECTION
        -- ========================================
        local hoverSection = Add(GUI:CreateCollapsibleSection(self.child, L["Hover Highlight"], true), 36, "both")
        currentSection = hoverSection
        
        local function HideHoverOptions(d) return d.hoverHighlightMode == "NONE" end
        
        local hoverGroup = GUI:CreateSettingsGroup(self.child, 280)
        hoverGroup:AddWidget(GUI:CreateHeader(self.child, L["Hover Settings"]), 40)
        hoverGroup:AddWidget(GUI:CreateDropdown(self.child, L["Mode"], highlightModes, db, "hoverHighlightMode", function()
            self:RefreshStates()
        end), 55)
        local hoverThick = hoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Thickness"], 1, 10, 1, db, "hoverHighlightThickness", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverThick.hideOn = HideHoverOptions
        local hoverInset = hoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Inset"], -10, 10, 1, db, "hoverHighlightInset", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverInset.hideOn = HideHoverOptions
        hoverInset.tooltip = TIP_HL_INSET
        local hoverAlpha = hoverGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "hoverHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverAlpha.hideOn = HideHoverOptions
        local hoverCol = hoverGroup:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "hoverHighlightColor", false, nil, function() DF:LightweightUpdateHighlight("hover") end, true), 35)
        hoverCol.hideOn = HideHoverOptions
        AddToSection(hoverGroup, nil, 1)
        
        currentSection = nil
        AddSpace(GUI.Space.section, "both")
        
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
        local aggroGroup = GUI:CreateSettingsGroup(self.child, 280)
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
        -- These two sound like the same thing and are not: one is about YOUR
        -- role, the other about the unit's. Both say which, from their side.
        aggroOnlyTanking.tooltip = L["Only highlight threat while YOU are tanking. As a healer or damage dealer the highlight stays off entirely."]
        local aggroHideOnTanks = aggroGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Hide on Tanks"], db, "aggroHideOnTanks", function()
            if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
        end), 28)
        aggroHideOnTanks.hideOn = HideAggroModeNone
        aggroHideOnTanks.tooltip = L["Skip the highlight on tanks in your group — they are supposed to have threat, so lighting them up is noise. Everyone else still shows."]
        local aggroThick = aggroGroup:AddWidget(GUI:CreateSlider(self.child, L["Thickness"], 1, 10, 1, db, "aggroHighlightThickness", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroThick.hideOn = HideAggroOptions
        local aggroInset = aggroGroup:AddWidget(GUI:CreateSlider(self.child, L["Inset"], -10, 10, 1, db, "aggroHighlightInset", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroInset.hideOn = HideAggroOptions
        aggroInset.tooltip = TIP_HL_INSET
        local aggroAlpha = aggroGroup:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0.1, 1.0, 0.05, db, "aggroHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroAlpha.hideOn = HideAggroOptions
        AddToSection(aggroGroup, nil, 1)
        
        -- Threat Colors Group (col2)
        local threatGroup = GUI:CreateSettingsGroup(self.child, 280)
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
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_dispel", label = L["Dispel Overlay"]},
        }), 30, "both")
    end)
    
    -- Auras > Dispel Overlay (moved from Indicators)
    local pageDispel = CreateSubTab("auras", "auras_dispel", L["Dispel Overlay"])
    BuildPage(pageDispel, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"dispel"}, L["Dispel Overlay"], "auras_dispel"), 25, 2)


        local function HideIfDisabled(d)
            return d.dispelOverlayEnabled == false
        end
        -- Alias kept so the widget wiring below reads unchanged — under the
        -- unified overlay every appearance control simply follows the toggle.
        local HideDispelOptions = HideIfDisabled

        -- 12.1: the container factory owns the overlay unconditionally
        -- (FactoryOwnsDispelOverlay == AuraContainer.IsSupported()), so the
        -- Display/Icon/Border/Gradient groups are always live here. The legacy
        -- "frost while the old path owns it" guards were unreachable and are gone.

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
        dispelIndicatorDropdown.tooltip = L["Dispellable By Me only lights up debuffs your current spec can actually remove. All Dispellable lights up every removable debuff, including ones for someone else to handle."]
        -- Dispel-type colours come from the shared account palette on the Colors page
        -- (defaults = the game palette; Reset restores it). The overlay always follows
        -- it — no game-vs-custom toggle — so this is just a link to where you edit them.
        local overlayColorsLink = GUI:CreateDispelColorsPageLink(self.child, 260)
        settingsGroup:AddWidget(overlayColorsLink, (overlayColorsLink.layoutHeight or 16) + 2)
        overlayColorsLink.hideOn = HideIfDisabled
        Add(settingsGroup, nil, 1)

        -- The four boxes below used to sit under an "Appearance" collapsible
        -- header -- the last section in the addon named for a CATEGORY rather
        -- than for a thing. A header means "here is another one of these",
        -- which is why Icons and Highlights keep theirs and this one goes.
        --
        -- It costs nothing to remove: every box already declares the same
        -- hideOn it was inheriting from the section, so the whole block still
        -- disappears when the overlay is off.

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
        -- (Color Name Text removed 2026-07-25 — see Features/Dispel.lua. Its only render
        -- path was the legacy test-mode show, so it tinted the preview and did nothing
        -- live; a real version needs an occlusion-safe name tint on the slot overlay.)
        displayGroup.hideOn = HideDispelOptions
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
        borderInset.tooltip = L["How far inside the frame edge the dispel border sits. Negative values push it outward, ringing the frame rather than hugging it."]
        local borderAlpha = borderGroup:AddWidget(GUI:CreateSlider(self.child, L["Border Opacity"], 0.1, 1.0, 0.1, db, "dispelBorderAlpha", function()
            InvalidateCurves()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        borderAlpha.hideOn = HideDispelOptions
        borderAlpha.disableOn = DisableIfNoBorder
        borderGroup.hideOn = HideDispelOptions   -- works in BOTH modes (game = ring slot)
        Add(borderGroup, nil, 2)

        -- ===== GRADIENT GROUP (Column 1) =====
        -- Column 1 with Display, not column 2 with Border: this is the OVERLAY's
        -- own gradient (Full Frame / Top Edge / Edge Glow), so it belongs with
        -- the overlay's display mode rather than with the border drawn over it.
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
        gradStyle.tooltip = L["Where the coloured wash sits on the frame. Full covers the whole bar; the edge options leave the middle clear so you can still read health and text underneath."]
        local onHealthCheck = gradientGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Show On Current Health Only"], db, "dispelGradientOnCurrentHealth", function()
            ApplyDispelSettings()
        end), 30)
        onHealthCheck.hideOn = function(d) return HideIfDisabled(d) or d.dispelGradientStyle ~= "FULL" end
        onHealthCheck.disableOn = DisableIfNoGradient
        onHealthCheck.tooltip = L["Keeps the wash inside the filled part of the health bar, so it shrinks as the unit takes damage instead of covering the empty section too."]
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
        darkenCheck.tooltip = L["Dims the frame underneath the wash so the dispel colour reads cleanly over a bright class colour or a busy health bar."]
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
        Add(gradientGroup, nil, 1)


        -- See Also links
        AddSpace(GUI.Space.block, "both")
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
        local currentGroup = GUI:CreateSettingsGroup(self.child, 280)
        currentGroup:AddWidget(GUI:CreateHeader(self.child, L["Current Profile"]), 40)
        currentGroup:AddWidget(GUI:CreateLabel(self.child, "|cff00ff00" .. currentProfile .. "|r", 240), 25)
        AddToSection(currentGroup, nil, 1)
        
        -- Available Profiles Group
        local listGroup = GUI:CreateSettingsGroup(self.child, 280)
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
            -- Standard theme hover: picking a profile IS the action of this page,
            -- so the row gets the same accent wash as any other button rather than
            -- the neutral "this is a place" grey. The "this is the active profile"
            -- cue is SetActive's accent fill + border, which stays visible under
            -- the hover (applyHoverState keeps the active border).
            local btn = CreateFrame("Button", nil, profileScrollChild, "BackdropTemplate")
            btn:SetPoint("TOPLEFT", 2, py)
            DF.GUI:StyleButton(btn, {
                width = 206, height = 24,
                text = p, font = "DFFontHighlightSmall",
            })
            btn:SetActive(p == currentProfile)
            btn:SetScript("OnClick", function() 
                DF:SetProfile(p) 
                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            end)
            py = py - 28
        end
        
        AddToSection(listGroup, nil, 1)
        
        -- Create New Profile Group
        local createGroup = GUI:CreateSettingsGroup(self.child, 280)
        createGroup:AddWidget(GUI:CreateHeader(self.child, L["Create New Profile"]), 40)
        
        local input = GUI:CreateInput(self.child, L["Profile Name"], 240)
        createGroup:AddWidget(input, 50)
        
        -- Button row for create actions
        local btnRow = CreateFrame("Frame", nil, self.child)
        btnRow:SetSize(240, 28)
        
        local createBtn = GUI:CreateButton(self.child, L["Create Empty"], 115, 24, function()
            local text = input.EditBox:GetText()
            if not text or text == "" then
                DF:Err("Please enter a profile name.")
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
                DF:Err("Please enter a name for the duplicated profile.")
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
        local actionsGroup = GUI:CreateSettingsGroup(self.child, 280)
        actionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Profile Actions"]), 40)
        
        actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "delete", L["Delete Current Profile"], 240, 26, function()
            local p = DF:GetCurrentProfile()
            if p == "Default" then
                DF:Err("Cannot delete Default profile.")
                return
            end
            -- The profile name rides the closure rather than the StaticPopup
            -- `data` field it used to be poked onto after the fact.
            DF:ShowPopupAlert({
                title   = L["Delete Profile"],
                message = format(L["Delete profile '%s'?\n\nThis cannot be undone."], p),
                buttons = {
                    {
                        label = L["Delete"],
                        onClick = function()
                            DF:SetProfile("Default")
                            DF:DeleteProfile(p)
                            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end, nil, "left"), 32)

        actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "refresh", L["Reset Profile to Defaults"], 240, 26, function()
            DF:ShowPopupAlert({
                title   = L["Reset Profile to Defaults"],
                message = L["Reset current profile to defaults?\nThis will reset BOTH Party and Raid settings."],
                buttons = {
                    {
                        label = L["Reset"],
                        onClick = function()
                            DF:ResetFullProfile()
                            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end, nil, "left"), 32)
        
        AddToSection(actionsGroup, nil, 2)
        
        -- Copy Settings Group
        local copyGroup = GUI:CreateSettingsGroup(self.child, 280)
        copyGroup:AddWidget(GUI:CreateHeader(self.child, L["Copy Settings"]), 40)
        copyGroup:AddWidget(GUI:CreateLabel(self.child, L["Copy all settings between Party and Raid modes."], 240), 25)
        
        -- Both directions are the same confirm with the modes swapped.
        local function ConfirmCopyProfile(src, dest, message)
            DF:ShowPopupAlert({
                title   = L["Copy Settings"],
                message = message,
                buttons = {
                    {
                        label = L["Copy"],
                        onClick = function()
                            DF:CopyProfile(src, dest)
                            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end

        copyGroup:AddWidget(GUI:CreateIconButton(self.child, "chevron_right", L["Party to Raid"], 240, 26, function()
            ConfirmCopyProfile("party", "raid",
                L["Copy Party settings to Raid?\n\nThis will overwrite all Raid settings with your current Party settings."])
        end, nil, "left"), 32)

        copyGroup:AddWidget(GUI:CreateIconButton(self.child, "chevron_right", L["Raid to Party"], 240, 26, function()
            ConfirmCopyProfile("raid", "party",
                L["Copy Raid settings to Party?\n\nThis will overwrite all Party settings with your current Raid settings."])
        end, nil, "left"), 32)
        
        AddToSection(copyGroup, nil, 2)
        
        -- Auto-Switch by Spec Group
        local specGroup = GUI:CreateSettingsGroup(self.child, 280)
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
        AddSpace(GUI.Space.block, "both")
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
        
        -- "What to Export" group: picks the profile, the mode and the categories.
        -- Named for the question it answers -- "Export Settings" read as both
        -- "settings for exporting" and "export your settings".
        local exportSettingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        exportSettingsGroup:AddWidget(GUI:CreateHeader(self.child, L["What to Export"]), 40)
        
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
            {name = "Look", x = 60, cats = {"bars", "auras", "dispel", "missingBuffs", "defensives", "targetedSpells", "targetedList", "text", "textDesigner", "icons", "other"}},
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
        local exportActionsGroup = GUI:CreateSettingsGroup(self.child, 280)
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
                DF:Say("Export generated.")
            elseif not str then
                DF:Err("Export failed - no string returned")
            end
        end), 32)
        
        -- Export text area
        local exportScrollContainer = GUI:CreateTextArea(self.child, { width = 240, height = 100 })
        self.exportEditBox = exportScrollContainer.EditBox

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
        local importStringGroup = GUI:CreateSettingsGroup(self.child, 280)
        importStringGroup:AddWidget(GUI:CreateHeader(self.child, L["Import String"]), 40)
        
        -- Import text area
        local importScrollContainer = GUI:CreateTextArea(self.child, { width = 240, height = 80 })
        self.importEditBox = importScrollContainer.EditBox

        importStringGroup:AddWidget(importScrollContainer, 85)
        
        -- Parse button
        importStringGroup:AddWidget(GUI:CreateButton(self.child, L["Parse String"], 240, 26, function()
            if not self.importEditBox then return end
            local str = self.importEditBox:GetText()
            if not str or str == "" then
                DF:Err("Paste a string first.")
                return
            end
            
            local importData, errMsg = DF:ValidateImportString(str)
            if not importData then
                DF:Err(errMsg)
                if self.importInfoLabel then self.importInfoLabel:SetText("|cffff6666Error: " .. errMsg .. "|r") end
                return
            end
            
            self.parsedImportData = importData
            local info = DF:GetImportInfo(importData)
            
            if self.importInfoLabel then
                self.importInfoLabel:SetText(string.format("|cff00ff00" .. L["OK"] .. "|r v%s %s%s",
                    (tostring(info.version):gsub("^[vV]", "")),
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
            
            DF:Say("Parsed. Select options and Import.")
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
        
        -- "What to Import" group: the target profile, the mode and the categories.
        -- Mirrors the export side; see the note there on why "Import Settings" went.
        local importSettingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        importSettingsGroup:AddWidget(GUI:CreateHeader(self.child, L["What to Import"]), 40)
        
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
        local importActionsGroup = GUI:CreateSettingsGroup(self.child, 280)
        importActionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Import"]), 40)
        
        -- Import button
        importActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "download", L["Import Selected"], 240, 26, function()
            if not self.parsedImportData then
                DF:Err("Parse a string first.")
                return
            end
            
            local selectedCats = {}
            for _, cat in ipairs(categoryOrder) do
                if self.importCheckboxes[cat]:GetChecked() then
                    table.insert(selectedCats, cat)
                end
            end
            
            if #selectedCats == 0 then
                DF:Err("Select at least one category.")
                return
            end
            
            local selectedFrameTypes = {
                party = self.importPartyCheck:GetChecked(),
                raid = self.importRaidCheck:GetChecked(),
            }
            
            if not selectedFrameTypes.party and not selectedFrameTypes.raid then
                DF:Err("Select Party or Raid.")
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
            
            -- Everything the accept needs is captured here rather than stapled
            -- onto the dialog afterwards, so there is no window in which the
            -- popup exists without its payload.
            local importData = self.parsedImportData
            DF:ShowPopupAlert({
                title   = L["Import Profile"],
                message = confirmText,
                buttons = {
                    {
                        label = L["Import"],
                        onClick = function()
                            if not importData then return end
                            DF:ApplyImportedProfile(importData, selectedCats, selectedFrameTypes, profileName, createNew)
                            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
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
        AddSpace(GUI.Space.block, "both")
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

        -- The log lives in SavedVariables, so one left behind is re-read from disk at
        -- every login until something clears it. 0 = keep forever, for anyone chasing
        -- a bug that only shows up across several days.
        -- "0 = never" is in the LABEL because CreateSlider has no value-label map to
        -- put it in: parameter 9 is `lightweightUpdate` (a per-drag-tick FUNCTION) and
        -- 10 is `usePreviewMode` (the boolean that arms it). Passing a table into
        -- either would read as truthy and quietly change how the slider commits.
        AddToSection(GUI:CreateSlider(self.child, L["Clear Log After (Days, 0 = Never)"],
            0, 30, 1, debugProxy, "logMaxAgeDays"), 55, 1)

        AddSyncPoint()

        -- ============================================================
        -- 2) LOGGED CATEGORIES SECTION
        -- ============================================================
        local categoriesSection = Add(GUI:CreateCollapsibleSection(self.child, L["Logged Categories"], true), 36, "both")
        currentSection = categoriesSection

        AddToSection(GUI:CreateNote(self.child,
            L["Unchecked categories are not logged at all. Disable noisy categories before reproducing a bug to keep the buffer focused."],
            { width = 540 }), 36, "both")


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

        local function SetAllFilters(value)
            if not (DandersFramesDB_v2 and DandersFramesDB_v2.debug) then return end
            local filters = DandersFramesDB_v2.debug.filters
            for cat in pairs(CollectAllCategories()) do
                filters[cat] = value
            end
            RefreshAllRows()
        end

        local filterBtnRow = GUI:CreateButtonRow(self.child, {
            { label = L["All"],  width = 60, onClick = function() SetAllFilters(true) end },
            { label = L["None"], width = 60, onClick = function() SetAllFilters(false) end },
            -- The baseline: everything on except the per-frame firehoses. All/None
            -- are blunt; this is the state you actually want to start an
            -- investigation from, and the way back after turning things on.
            { label = L["Default"], width = 80,
              onClick = function()
                  if DF.DebugConsole and DF.DebugConsole:ApplyDefaultFilters() then
                      RefreshAllRows()
                  end
              end,
              tooltip = {
                  title = L["Default"],
                  lines = {
                      L["Turns every category on except the noisy ones, which log many lines per frame during layout and sorting."],
                      L["Enable those only while reproducing a layout or sorting bug."],
                  },
              } },
        }, { height = 22 })

        AddToSection(filterBtnRow, 28, "both")

        -- One colour for the category-group headings, passed to CreateLabel rather
        -- than baked into each string as a |c escape -- an escape inside a
        -- localised string is invisible to translators and easy to unbalance.
        local GROUP_HEADING_COLOR = { r = 0.93, g = 0.65, b = 0.37 }

        if DF.DebugConsole then
            local groups = DF.DebugConsole:GetCategoryGroups()
            for _, group in ipairs(groups) do
                local groupLabel = L[group.name] or group.name
                AddToSection(GUI:CreateLabel(self.child, groupLabel, 540, GROUP_HEADING_COLOR), 22, "both")
                for _, cat in ipairs(group.categories) do
                    -- The firehoses are marked in the row itself, so "why is this
                    -- one off?" is answered where the user is looking rather than
                    -- only in the Default button's tooltip. The row renders it as
                    -- the shared caution icon; it used to be a "(noisy)" suffix
                    -- concatenated onto the description.
                    local row = GUI:CreateDebugCategoryRow(self.child, cat.key, cat.desc, 540, cat.noisy)
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
                AddToSection(GUI:CreateLabel(self.child, L["Discovered"], 540, GROUP_HEADING_COLOR), 22, "both")
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
            -- No |c escape: CreateLabel's default colour is already the dim body tone.
            entryCountLabel:SetText(format(L["Log entries: %d"], count))
        end
        UpdateEntryCount()
        AddToSection(entryCountLabel, 20, "both")

        -- Action buttons row (Refresh / Clear Log / Copy to Clipboard)
        local function CopyLogToClipboard()
            if not DF.DebugConsole then return end
            -- Was a hand-rolled dialog: ~35 lines building its own frame, backdrop,
            -- title, drag handlers and close button. ☠ It also called CreateFrame
            -- with the FIXED global name "DFDebugExportPopup" on every click, so a
            -- second export built a second frame over the same global and orphaned
            -- the first — a leak per click. The shared input popup is a singleton
            -- and is the same control the click-cast profile export already uses.
            DF:ShowPopupInput({
                title       = L["Debug Log Export (Filtered)"],
                message     = L["Press Ctrl+A to select all, then Ctrl+C to copy"],
                text        = DF.DebugConsole:GetExportText(),
                multiline   = true,
                readOnly    = true,
                cancelLabel = L["Close"],
            })
        end

        local actionRow = GUI:CreateButtonRow(self.child, {
            { label = L["Refresh"], width = 100, onClick = function()
                if DF.DebugConsole then
                    DF.DebugConsole:RefreshDisplay()
                    UpdateEntryCount()
                end
            end },
            { label = L["Clear Log"], width = 100, onClick = function()
                if DF.DebugConsole then
                    DF.DebugConsole:ClearLog()
                    UpdateEntryCount()
                end
            end },
            { label = L["Copy to Clipboard"], width = 140, onClick = CopyLogToClipboard },
        })

        AddToSection(actionRow, 32, "both")

        -- Full-width log viewer
        local logScrollContainer = GUI:CreateTextArea(self.child, {
            width = 540, height = 480,
            -- Typing in the log is not an edit — it just re-renders the buffer.
            onTextChanged = function(_, userInput)
                if userInput and DF.DebugConsole then
                    DF.DebugConsole:RefreshDisplay()
                end
            end,
        })
        local logEditBox = logScrollContainer.EditBox

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

        local scriptScrollContainer = GUI:CreateTextArea(self.child, {
            width = 540, height = 120,
            text = (DandersFramesDB_v2 and DandersFramesDB_v2.debug
                    and DandersFramesDB_v2.debug.lastScript) or nil,
            onTextChanged = function(text, userInput)
                if userInput and DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                    DandersFramesDB_v2.debug.lastScript = text
                end
            end,
        })
        local scriptEditBox = scriptScrollContainer.EditBox

        AddToSection(scriptScrollContainer, 125, "both")

        local scriptStatusLabel = GUI:CreateLabel(self.child, "", 540)
        AddToSection(scriptStatusLabel, 20, "both")

        -- Status is a TONE, not an ad-hoc colour: these were five hand-picked hex
        -- values that drifted from the info/caution/danger/success language every
        -- banner, note and tooltip in the GUI already speaks. ToneHex is the one
        -- source for the inline form.
        local function SetScriptStatus(text, tone)
            if tone then
                scriptStatusLabel:SetText("|c" .. GUI:ToneHex(tone) .. text .. "|r")
            else
                scriptStatusLabel:SetText(text)   -- default dim body tone
            end
        end

        AddToSection(GUI:CreateButton(self.child, L["Run Script"], 540, 26, function()
            local code = scriptEditBox:GetText()
            if not code or code == "" then
                SetScriptStatus(L["No script to run."])
                return
            end
            local fn, err = loadstring(code)
            if not fn then
                SetScriptStatus(format(L["Error: %s"], tostring(err)), "danger")
                DF:DebugError("SCRIPT", "Compile error: %s", tostring(err))
                return
            end
            local ok, result = pcall(fn)
            if ok then
                if result ~= nil then
                    SetScriptStatus(format(L["Result: %s"], tostring(result)), "info")
                else
                    SetScriptStatus(L["Script executed successfully."], "success")
                end
            else
                SetScriptStatus(format(L["Runtime: %s"], tostring(result)), "danger")
                DF:DebugError("SCRIPT", "Runtime error: %s", tostring(result))
            end
        end), 32, "both")

        currentSection = nil
    end)

end
