-- Part 4 of the Aura Designer editor, split from Options.lua.
-- Aliases of objects the first part created; they add no state.
local addonName, DF = ...
local L = DF.L
local GUI = DF.GUI
local Adapter = DF.AuraDesigner.Adapter
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv
local C_ELEMENT = GUI.Colors.element
local C_BORDER = GUI.Colors.border
local C_HOVER = GUI.Colors.hover
local C_TEXT = GUI.Colors.text
local C_TEXT_DIM = GUI.Colors.textDim
local OPTS = P.OPTS
local GetAuraDesignerDB = P.GetAuraDesignerDB
local GetThemeColor = P.GetThemeColor
local ApplyBackdrop = P.ApplyBackdrop
local CreateCardShell = P.CreateCardShell
local ShowBuffCoexistPopup = P.ShowBuffCoexistPopup
local ResolveSpec = P.ResolveSpec
local IsOtherTab = P.IsOtherTab
local IsDebuffTab = P.IsDebuffTab
local CurrentAuraPool = P.CurrentAuraPool
local PoolKeyPrefix = P.PoolKeyPrefix
local OtherPoolDisplayName = P.OtherPoolDisplayName
local CrossPoolTrackedIDs = P.CrossPoolTrackedIDs
local EnsureTypeConfig = P.EnsureTypeConfig
local TYPE_DEFAULTS = P.TYPE_DEFAULTS
local CreateIndicatorInstance = P.CreateIndicatorInstance
local RemoveIndicatorInstance = P.RemoveIndicatorInstance
local RefreshLiveFramesThrottled = P.RefreshLiveFramesThrottled
local AddDurationColorsLink = P.AddDurationColorsLink
local CreateInstanceProxy = P.CreateInstanceProxy
local CreateProxy = P.CreateProxy
local CreateAuraProxy = P.CreateAuraProxy
local GetAuraWarningKey = P.GetAuraWarningKey
local AttachWarningBadge = P.AttachWarningBadge
local WithConfiguredAdHocAuras = P.WithConfiguredAdHocAuras
local GetAuraIcon = P.GetAuraIcon
local GetFrameEffectTriggers = P.GetFrameEffectTriggers
local AddFrameEffectTrigger = P.AddFrameEffectTrigger
local RemoveFrameEffectTrigger = P.RemoveFrameEffectTrigger
local CloseADPicker = P.CloseADPicker
local GetIndicatorLayoutGroup = P.GetIndicatorLayoutGroup
local GetLayoutGroupByID = P.GetLayoutGroupByID
local AddGroupMember = P.AddGroupMember
local anchorDots = P.anchorDots
local ANCHOR_POSITIONS = P.ANCHOR_POSITIONS
local expandedCards = P.expandedCards
local tabButtons = P.tabButtons
local mainTabButtons = P.mainTabButtons
local BADGE_COLORS = P.BADGE_COLORS
local CollectAllEffects = P.CollectAllEffects
local IsAuraTypePlaced = P.IsAuraTypePlaced
local dragState = P.dragState
local RefreshPlacedIndicators = P.RefreshPlacedIndicators
local RefreshPreviewEffects = P.RefreshPreviewEffects
local BuildTypeContent = P.BuildTypeContent

-- ============================================================
-- GLOBAL VIEW (used by Global tab)
-- ============================================================

-- Hardcoded fallbacks for global defaults (used when profile is missing new keys)
local GLOBAL_DEFAULTS_FALLBACK = {
    iconSize = 24, iconScale = 1.0,
    showDuration = true, showStacks = true,
    durationFont = "DF Roboto SemiBold", durationScale = 1.2,
    durationOutline = "SHADOW;OUTLINE", durationAnchor = "CENTER",
    durationX = 0, durationY = 0, durationColorByTime = true,
    durationColor = {r = 1, g = 1, b = 1, a = 1},
    durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
    stackFont = "DF Roboto SemiBold", stackScale = 1.0,
    stackOutline = "SHADOW;OUTLINE", stackAnchor = "BOTTOMRIGHT",
    stackX = 2, stackY = -2,
    stackColor = {r = 1, g = 1, b = 1, a = 1},
    iconBorderEnabled = true, iconBorderThickness = 1,
    hideSwipe = false, hideIcon = false,
}

local function BuildGlobalView(parent)
    local adDB = GetAuraDesignerDB()
    local rawDefaults = adDB.defaults
    -- Proxy so every write triggers a full preview rebuild
    -- (global defaults affect ALL indicators, need full teardown/rebuild)
    -- Falls back to GLOBAL_DEFAULTS_FALLBACK for keys missing from existing profiles.
    -- __dfDefaults exposes the fallback table to GUI:CreateColorPicker's Default button.
    local defaults = setmetatable({ _skipOverrideIndicators = true, __dfDefaults = GLOBAL_DEFAULTS_FALLBACK }, {
        __index = function(_, k)
            local v = rawDefaults[k]
            if v ~= nil then return v end
            return GLOBAL_DEFAULTS_FALLBACK[k]
        end,
        __newindex = function(_, k, v)
            rawDefaults[k] = v
            RefreshPlacedIndicators()
            RefreshPreviewEffects()
            RefreshLiveFramesThrottled()
        end,
    })

    local parentW = parent:GetWidth()
    if parentW < 50 then parentW = 280 end
    local contentWidth = parentW - 16  -- 8px padding each side
    local totalHeight = 8
    local widgets = {}
    local function RPL() if S.RefreshPreviewLightweight then S.RefreshPreviewLightweight() end end

    local function AddWidget(widget, height)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -totalHeight)
        if widget.SetWidth then widget:SetWidth(contentWidth - 10) end
        tinsert(widgets, widget)
        totalHeight = totalHeight + (height or 30)
    end

    local function AddGroup(header, buildFn)
        local group = GUI:CreateSettingsGroup(parent, contentWidth - 10)
        group.padding = 10   -- match the main Options groups' inner padding (airier scale)
        group:AddWidget(GUI:CreateHeader(parent, header), GUI.RowHeight.sectionHeader)
        buildFn(group)
        local h = group:LayoutChildren()
        AddWidget(group, h)
    end

    -- ── GENERAL ──
    AddGroup(L["General"], function(g)
        g:AddWidget(GUI:CreateSlider(parent, L["Default Icon Size"], 8, 64, 1, defaults, "iconSize"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Default Scale"], 0.5, 3.0, 0.05, defaults, "iconScale"), 50)
        -- Both LIVE on the container path: Factory.ResolveDefaults bundles them into the
        -- per-pass `defs` table, resolveLevel/resolveStrata walk instance -> global default
        -- (the same chain GLOBAL_DEFAULT_MAP gives the editor proxy, so the two agree), and
        -- AuraContainer's _applyZOrder sets level and strata from the resolved config.
        -- Both ship as no-ops -- level 0, strata INHERIT -- so an untouched profile renders
        -- exactly where it did before they were wired.
        g:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Default Frame Level"], 0, 100, 1, defaults, "indicatorFrameLevel")), 50)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], defaults, "showDuration"), 24)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Show Stacks"], defaults, "showStacks"), 24)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], defaults, "hideSwipe"), 24)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Icon (Text Only)"], defaults, "hideIcon"), 24)
    end)

    -- ── SOUND ALERTS ──
    -- Set-once settings, relocated here from the enable banner (§11.6 redesign).
    -- Storage keys unchanged: soundEnabled (nil/true = on, false = muted) and
    -- soundChannel (Master default: alerts should stay audible when the player
    -- mutes Sound Effects/Music to cut combat noise).
    AddGroup(L["Sound Alerts"], function(g)
        local SOUND_CHANNELS = {
            Master   = L["Master"],
            SFX      = L["Sound Effects"],
            Music    = L["Music"],
            Ambience = L["Ambience"],
            Dialog   = L["Dialog"],
            _order   = { "Master", "SFX", "Music", "Ambience", "Dialog" },
        }
        g:AddWidget(GUI:CreateCheckbox(parent, L["Enabled"], nil, nil, nil,
            function() return GetAuraDesignerDB().soundEnabled ~= false end,   -- customGet
            function(v)                                                        -- customSet
                local adDB = GetAuraDesignerDB()
                adDB.soundEnabled = v and true or false
                if not adDB.soundEnabled and DF.AuraDesigner.SoundEngine then
                    DF.AuraDesigner.SoundEngine:StopAll()
                end
            end), 24)
        g:AddWidget(GUI:CreateDropdown(parent, L["Channel"], SOUND_CHANNELS,
            nil, nil, nil,
            function() return (GetAuraDesignerDB().soundChannel) or "Master" end,  -- customGet
            function(key) GetAuraDesignerDB().soundChannel = key end), 50)         -- customSet
    end)

    -- ── DURATION TEXT ──
    AddGroup(L["Duration Text"], function(g)
        g:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], defaults, "durationFont"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.0, 0.1, defaults, "durationScale"), 50)
        g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], defaults, "durationOutline"), 54)
        g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], defaults, "durationOutline"), 28)
        g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, defaults, "durationAnchor"), 54)
        g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, defaults, "durationX"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, defaults, "durationY"), 50)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], defaults, "durationColorByTime"), 24)
        AddDurationColorsLink(g, parent)
        g:AddWidget(GUI:CreateColorPicker(parent, L["Duration Text Color"], defaults, "durationColor", true, RPL, RPL, true), 32)
        local hideAboveSlider
        local function UpdateHideAboveState()
            if not hideAboveSlider then return end
            if defaults.durationHideAboveEnabled then
                hideAboveSlider:SetAlpha(1)
                hideAboveSlider:EnableMouse(true)
            else
                hideAboveSlider:SetAlpha(0.4)
                hideAboveSlider:EnableMouse(false)
            end
        end
        g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration Above Threshold"], defaults, "durationHideAboveEnabled", UpdateHideAboveState), 24)
        hideAboveSlider = GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, defaults, "durationHideAboveThreshold")
        g:AddWidget(hideAboveSlider, 50)
        UpdateHideAboveState()
    end)

    -- ── STACK TEXT ──
    AddGroup(L["Stack Text"], function(g)
        g:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], defaults, "stackFont"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.0, 0.1, defaults, "stackScale"), 50)
        g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], defaults, "stackOutline"), 54)
        g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], defaults, "stackOutline"), 28)
        g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, defaults, "stackAnchor"), 54)
        g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, defaults, "stackX"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, defaults, "stackY"), 50)
        g:AddWidget(GUI:CreateColorPicker(parent, L["Stack Text Color"], defaults, "stackColor", true, RPL, RPL, true), 32)
    end)

    -- ── IMPORT FROM BUFFS TAB ──
    AddGroup(L["Import from Buffs Tab"], function(g)
        local descFrame = CreateFrame("Frame", nil, parent)
        descFrame:SetHeight(36)
        local descText = descFrame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descText:SetPoint("TOPLEFT", 0, 0)
        descText:SetPoint("RIGHT", descFrame, "RIGHT", 0, 0)
        descText:SetJustifyH("LEFT")
        descText:SetWordWrap(true)
        descText:SetText(L["Import your existing Buffs tab settings as defaults for all auras. Compatible settings will be applied automatically."])
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        g:AddWidget(descFrame, 36)

        -- Compatibility list
        local compatItems = {
            {true,  L["Icon size, scale & border"]},
            {true,  L["Duration & stack display"]},
            {true,  L["Font Settings"]},
            {false, L["Position & anchors"]},
            {false, L["Per-aura overrides"]},
        }
        for _, item in ipairs(compatItems) do
            local isCompat = item[1]
            local row = CreateFrame("Frame", nil, parent)
            row:SetHeight(16)
            local lbl = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            lbl:SetPoint("TOPLEFT", 8, 0)
            if isCompat then
                lbl:SetText("|TInterface\\AddOns\\DandersFrames\\Media\\Icons\\check:12:12|t  " .. item[2])
            else
                lbl:SetText("|TInterface\\AddOns\\DandersFrames\\Media\\Icons\\close:12:12|t  " .. item[2])
            end
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            g:AddWidget(row, 16)
        end

        -- Import button
        local importBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        DF.GUI:StyleButton(importBtn, { height = 26, text = L["Import Buffs Tab Defaults"] })
        importBtn:SetScript("OnClick", function()
            local mode = (GUI and GUI.SelectedMode) or "party"
            local buffsDB = DF:GetDB(mode)
            if buffsDB and defaults then
                if buffsDB.buffSize then defaults.iconSize = buffsDB.buffSize end
                if buffsDB.buffScale then defaults.iconScale = buffsDB.buffScale end
                if buffsDB.buffShowDuration ~= nil then defaults.showDuration = buffsDB.buffShowDuration end
                if buffsDB.buffShowStacks ~= nil then defaults.showStacks = buffsDB.buffShowStacks end
                if buffsDB.buffBorder ~= nil then defaults.iconBorderEnabled = buffsDB.buffBorder end
                if buffsDB.buffDurationFont then defaults.durationFont = buffsDB.buffDurationFont end
                if buffsDB.buffDurationScale then defaults.durationScale = buffsDB.buffDurationScale end
                if buffsDB.buffDurationOutline then defaults.durationOutline = buffsDB.buffDurationOutline end
                if buffsDB.buffStackFont then defaults.stackFont = buffsDB.buffStackFont end
                if buffsDB.buffStackScale then defaults.stackScale = buffsDB.buffStackScale end
                if buffsDB.buffStackOutline then defaults.stackOutline = buffsDB.buffStackOutline end
                DF:Debug("AD", "Imported Buffs tab defaults")
                importBtn.Text:SetText(L["Imported!"])
                C_Timer.After(1.5, function() importBtn.Text:SetText(L["Import Buffs Tab Defaults"]) end)
                DF:AuraDesigner_RefreshPage()
            end
        end)
        g:AddWidget(importBtn, 32)
    end)

    -- ── STANDARD BUFFS ──
    -- Replaces the old coexistence banner's "Disable Buffs" shortcut: standard
    -- buff visibility is Aura Filters' job now, so this just links there.
    AddGroup(L["Standard Buffs"], function(g)
        local descFrame = CreateFrame("Frame", nil, parent)
        descFrame:SetHeight(24)
        local descText = descFrame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descText:SetPoint("TOPLEFT", 0, 0)
        descText:SetPoint("RIGHT", descFrame, "RIGHT", 0, 0)
        descText:SetJustifyH("LEFT")
        descText:SetWordWrap(true)
        descText:SetText(L["Standard buff visibility is managed on the Aura Filters S.page."])
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        g:AddWidget(descFrame, 24)

        local filtersBtn = GUI:CreateButton(parent, L["Aura Filters"], 140, 22, function()
            if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
                GUI.SelectTab("auras_filterdesigner")
            end
        end)
        if not (GUI.Pages and GUI.Pages["auras_filterdesigner"]) then
            filtersBtn:Disable()
            filtersBtn.Text:SetTextColor(0.4, 0.4, 0.4)
        end
        g:AddWidget(filtersBtn, 28)
    end)

    -- ── ACTIONS ──
    AddGroup(L["Actions"], function(g)
        -- Copy Settings to Other Mode button
        local currentMode = (GUI and GUI.SelectedMode) or "party"
        local targetMode = (currentMode == "party") and "raid" or "party"
        local targetLabel = (targetMode == "raid") and L["Raid"] or L["Party"]

        local copyBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        DF.GUI:StyleButton(copyBtn, { height = 26, text = format(L["Copy Settings to %s"], targetLabel) })
        copyBtn:SetScript("OnClick", function()
            local srcMode = (GUI and GUI.SelectedMode) or "party"
            local dstMode = (srcMode == "party") and "raid" or "party"
            -- Copy at the preset level: the source mode's preset content is
            -- copied INTO the dest mode's preset, in place, so the dest preset
            -- object identity (and every consumer bound to it) is preserved.
            -- BASE resolvers: this S.page edits the user's BASE presets — with a
            -- runtime auto-layout active, the ACTIVE resolver would copy
            -- from/into the layout's preset instead.
            local source = (DF.GetModeBaseAuraDesigner and DF:GetModeBaseAuraDesigner(srcMode))
                or (DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(srcMode))
                or (DF:GetDB(srcMode) and DF:GetDB(srcMode).auraDesigner)
            local dest = (DF.GetModeBaseAuraDesigner and DF:GetModeBaseAuraDesigner(dstMode))
                or (DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(dstMode))
                or (DF:GetDB(dstMode) and DF:GetDB(dstMode).auraDesigner)
            if source and dest and source ~= dest then
                local function DeepCopy(src)
                    if type(src) ~= "table" then return src end
                    local copy = {}
                    for k, v in pairs(src) do copy[k] = DeepCopy(v) end
                    return copy
                end
                -- Clear stale dest keys the source no longer has, then overwrite.
                for k in pairs(dest) do dest[k] = nil end
                for k, v in pairs(source) do dest[k] = DeepCopy(v) end
            end
            DF:Debug("AD", "Copied %s settings to %s", tostring(srcMode), tostring(dstMode))
        end)
        g:AddWidget(copyBtn, 32)

        -- Reset All button
        local resetBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        resetBtn:SetHeight(26)
        -- Persistent-red destructive button via the shared styler, now gated by a
        -- confirmation (was a one-click wipe).
        DF.GUI:StyleButton(resetBtn, { height = 26, primary = true, accent = { r = 0.8, g = 0.25, b = 0.25 }, text = L["Reset All Aura Configs"] })
        resetBtn:SetScript("OnClick", function()
            DF:ShowPopupAlert({
                title = L["Reset All Aura Configs"],
                message = L["Reset ALL aura configurations to defaults?\n\nThis cannot be undone."],
                buttons = {
                    {
                        label = L["Reset"],
                        onClick = function()
                            wipe(GetAuraDesignerDB().auras)
                            -- "Reset ALL" covers the Other Buffs pool too (B2)
                            if GetAuraDesignerDB().otherAuras then
                                wipe(GetAuraDesignerDB().otherAuras)
                            end
                            DF:AuraDesigner_RefreshPage()
                            RefreshLiveFramesThrottled()
                            DF:Debug("AD", "Reset all aura configurations")
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end)
        g:AddWidget(resetBtn, 32)
    end)

    parent:SetHeight(totalHeight + 10)
end

-- BuildPerAuraView + RefreshRightPanel removed in v4 redesign
-- Per-aura configuration is now done via flat effect cards in the Effects tab
-- (their dummy stubs were unreferenced — reclaimed for the 200-locals ceiling)

-- ============================================================
-- ENABLE BANNER
-- ============================================================

local function CreateEnableBanner(parent)
    local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    -- Two-row layout: row 1 (36px) has Enable toggle (left) + Sync/Copy buttons
    -- (right); row 2 (32px) is the preset bar (anchored into the banner by the
    -- S.page build; the spec dropdown moved onto the B2 main tab strip). Sound
    -- Alerts live on the Global tab (set-once settings).
    banner:SetHeight(68)
    banner:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    banner:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    GUI:CreatePanelBackdrop(banner, {borderColor = {r = 0.30, g = 0.30, b = 0.30, a = 0.5}})

    -- Subtle divider between the two rows
    local rowDivider = banner:CreateTexture(nil, "BACKGROUND")
    rowDivider:SetHeight(1)
    rowDivider:SetPoint("TOPLEFT", banner, "TOPLEFT", 0, -36)
    rowDivider:SetPoint("TOPRIGHT", banner, "TOPRIGHT", 0, -36)
    rowDivider:SetColorTexture(0.25, 0.25, 0.25, 1)

    -- Themed checkbox (matches GUI:CreateCheckbox style)
    -- Row 1 centre = 18px from top. Banner centre = 34px from top.
    -- Offset from banner centre to row 1 centre = +16.
    local cb = CreateFrame("CheckButton", nil, banner, "BackdropTemplate")
    cb:SetPoint("LEFT", banner, "LEFT", 10, 16)
    DF.GUI:StyleCheckButton(cb)

    local adDB = GetAuraDesignerDB()
    cb:SetChecked(adDB and adDB.enabled)

    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        if checked then
            -- Show popup asking about buff coexistence
            ShowBuffCoexistPopup(function(keepBuffs)
                GetAuraDesignerDB().enabled = true
                S.db.showBuffs = keepBuffs
                DF:AuraDesigner_RefreshPage()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end, function()
                -- Cancelled — revert checkbox
                self:SetChecked(false)
            end)
        else
            GetAuraDesignerDB().enabled = false
            DF:AuraDesigner_RefreshPage()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            -- Sync AD indicators to the now-disabled state — clears the leftover
            -- indicators instead of leaving them frozen on screen until /reload.
            if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
        end
    end)

    local cbLabel = banner:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    cbLabel:SetText(L["Enable Aura Designer"])
    cbLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    banner.checkbox = cb
    return banner
end
P.CreateEnableBanner = CreateEnableBanner

-- ============================================================
-- SPEC DROPDOWN (B2: relocated from the enable banner onto the
-- main tab strip's right end — it only applies to My Buffs; the
-- Other Buffs tab greys it with a "shared across specs" caption)
-- ============================================================

local function CreateSpecDropdown(parent)
    -- Spec selector. Ported to the shared GUI:CreateDropdown (inline mode, so the
    -- container is just the opener button — the "Spec:" label beside it is
    -- hand-placed by the S.page build). optionsFunc rebuilds the list each open so
    -- the "Auto (Spec Name)" text always reflects the live detected spec.
    -- The shared dropdown supports per-option colour (the `color` field), so the
    -- class-coloured menu entries are preserved. (The OPENER text stays standard
    -- colour — the shared opener isn't per-value colourable.)
    local SPEC_ORDER = {
        "auto",
        -- Grouped by class (class order), specs in spec-index order
        "ArmsWarrior", "FuryWarrior", "ProtectionWarrior",
        "HolyPaladin", "ProtectionPaladin", "RetributionPaladin",
        "BeastMasteryHunter", "MarksmanshipHunter", "SurvivalHunter",
        "AssassinationRogue", "OutlawRogue", "SubtletyRogue",
        "DisciplinePriest", "HolyPriest", "ShadowPriest",
        "BloodDeathKnight", "FrostDeathKnight", "UnholyDeathKnight",
        "ElementalShaman", "EnhancementShaman", "RestorationShaman",
        "ArcaneMage", "FireMage", "FrostMage",
        "AfflictionWarlock", "DemonologyWarlock", "DestructionWarlock",
        "BrewmasterMonk", "MistweaverMonk", "WindwalkerMonk",
        "BalanceDruid", "FeralDruid", "GuardianDruid", "RestorationDruid",
        "HavocDemonHunter", "VengeanceDemonHunter", "DevourerDemonHunter",
        "DevastationEvoker", "PreservationEvoker", "AugmentationEvoker",
    }
    local function SpecOptionText(specKey)
        if specKey == "auto" then
            local autoSpec = Adapter:GetPlayerSpec()
            if autoSpec then
                return format(L["Auto (%s)"], Adapter:GetSpecDisplayName(autoSpec))
            end
            return L["Auto (detect spec)"]
        end
        return Adapter:GetSpecDisplayName(specKey)
    end
    local function SpecOptionColor(specKey)
        local resolved = specKey
        if specKey == "auto" then resolved = Adapter:GetPlayerSpec() end
        local info = resolved and DF.AuraDesigner.SpecInfo and DF.AuraDesigner.SpecInfo[resolved]
        local cc = info and info.class and RAID_CLASS_COLORS[info.class]
        if cc then return { r = cc.r, g = cc.g, b = cc.b } end
        return nil
    end
    -- All-spec menu: "Auto (<detected>)" pinned first, then every spec grouped
    -- under a class-coloured header row, with the shared dropdown's inline
    -- search (opts.searchable) so 41 entries stay navigable.
    local function BuildSpecOptions()
        local order = {}
        local options = { _order = order }
        tinsert(order, "auto")
        options.auto = {
            value = "auto",
            text = SpecOptionText("auto"),
            color = SpecOptionColor("auto"),
        }
        local lastClass
        for _, specKey in ipairs(SPEC_ORDER) do
            if specKey ~= "auto" then
                local info = DF.AuraDesigner.SpecInfo and DF.AuraDesigner.SpecInfo[specKey]
                local classToken = info and info.class
                if classToken and classToken ~= lastClass then
                    lastClass = classToken
                    local hdrKey = "__hdr_" .. classToken
                    local cc = RAID_CLASS_COLORS[classToken]
                    tinsert(order, hdrKey)
                    options[hdrKey] = {
                        header = true,
                        text = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken]) or classToken,
                        color = cc and { r = cc.r, g = cc.g, b = cc.b } or nil,
                    }
                end
                tinsert(order, specKey)
                options[specKey] = {
                    value = specKey,
                    text = SpecOptionText(specKey),
                    color = SpecOptionColor(specKey),
                }
            end
        end
        return options
    end

    local specDrop = GUI:CreateDropdown(
        parent, "", BuildSpecOptions(),
        nil, nil, nil,
        function() return GetAuraDesignerDB().spec or "auto" end,   -- customGet
        function(key)                                                -- customSet
            GetAuraDesignerDB().spec = key
            -- Clear expanded cards (auras change with spec), and close the
            -- shared spell picker — its records/handlers captured the OLD
            -- spec's state at open time (same staleness as a tab switch).
            wipe(expandedCards)
            CloseADPicker()
            DF:AuraDesigner_RefreshPage()
        end,
        -- menuAlign RIGHT: the opener sits near the strip's right side and the
        -- menu is wider than it, so surplus width grows leftward (menu TOPRIGHT
        -- pinned to the opener's BOTTOMRIGHT) instead of spilling off the edge.
        { inline = true, optionsFunc = BuildSpecOptions, searchable = true, menuAlign = "RIGHT" }
    )

    local function UpdateSpecText()
        if specDrop.RebuildOptions then specDrop:RebuildOptions(BuildSpecOptions()) end
        if specDrop.UpdateText then specDrop:UpdateText() end
    end

    return specDrop, UpdateSpecText
end
P.CreateSpecDropdown = CreateSpecDropdown

-- ============================================================
-- FRAME PREVIEW
-- Mock unit frame with health bar, power bar, name, health %,
-- and 9 anchor point dots for indicator placement
-- ============================================================

local function CreateFramePreview(parent, yOffset, rightPanelRef)
    -- Read current frame settings for the preview
    local mode = (GUI and GUI.SelectedMode) or "party"
    local frameDB = DF:GetDB(mode) or DF.PartyDefaults
    local FRAME_W = frameDB.frameWidth or 125
    local FRAME_H = frameDB.frameHeight or 64
    local POWER_H = frameDB.powerBarHeight or 4
    local showPower = frameDB.showPowerBar

    -- Preview scale from AD settings
    local adDB = GetAuraDesignerDB()
    local previewScale = adDB.previewScale or 1.0

    -- Outer container with label
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local rightInset = rightPanelRef and (rightPanelRef:GetWidth() + 6) or 0
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -rightInset, yOffset)
    container:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    container:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -rightInset, 0)
    -- Dark bg + DIM border (matches Text Designer; no solid white outline).
    ApplyBackdrop(container, {r = 0.10, g = 0.10, b = 0.10, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})
    -- Apply the subtle spec class-color hint immediately. CreateFramePreview runs
    -- on every S.page build — including a party/raid rebuild (S.page:Refresh always
    -- rebuilds) — so without this the new preview falls back to the dim default
    -- border until the next AuraDesigner_RefreshPage (spec change / tab revisit).
    local cbSpec = ResolveSpec()
    local cbInfo = cbSpec and DF.AuraDesigner.SpecInfo and DF.AuraDesigner.SpecInfo[cbSpec]
    local cbColor = cbInfo and cbInfo.class and RAID_CLASS_COLORS[cbInfo.class]
    if cbColor then
        container:SetBackdropBorderColor(cbColor.r, cbColor.g, cbColor.b, 0.5)
    end

    -- "Frame Preview" label
    local previewLabel = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    previewLabel:SetPoint("TOPLEFT", 8, -4)
    previewLabel:SetText(L["FRAME PREVIEW"])
    previewLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Mock unit frame (centered in container)
    local mockFrame = CreateFrame("Frame", nil, container, "BackdropTemplate")
    mockFrame:SetSize(FRAME_W, FRAME_H)
    mockFrame:SetPoint("CENTER", container, "CENTER", 0, -4)
    mockFrame:SetScale(previewScale)
    ApplyBackdrop(mockFrame, {r = 0.07, g = 0.07, b = 0.07, a = 1}, {r = 0.27, g = 0.27, b = 0.27, a = 1})
    container.mockFrame = mockFrame

    -- Resolve health texture
    local healthTexPath = frameDB.healthTexture or "Interface\\Buttons\\WHITE8x8"

    -- Health bar background
    local healthBg = mockFrame:CreateTexture(nil, "BACKGROUND")
    healthBg:SetPoint("TOPLEFT", 1, -1)
    if showPower then
        healthBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H + 1)
    else
        healthBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 1)
    end
    healthBg:SetColorTexture(0, 0, 0, 0.4)
    -- Exposed so the preview can tint the background when an AD Background Color
    -- effect is configured.
    container.healthBg = healthBg

    -- Health bar fill (72% health)
    local healthFill = mockFrame:CreateTexture(nil, "ARTWORK")
    healthFill:SetPoint("TOPLEFT", 1, -1)
    if showPower then
        healthFill:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, POWER_H + 1)
    else
        healthFill:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, 1)
    end
    healthFill:SetWidth(FRAME_W * 0.72)
    healthFill:SetTexture(healthTexPath)
    healthFill:SetVertexColor(0.18, 0.80, 0.44, 0.85)
    container.healthFill = healthFill

    -- Missing health region
    local missingHealth = mockFrame:CreateTexture(nil, "ARTWORK")
    missingHealth:SetPoint("TOPRIGHT", mockFrame, "TOPRIGHT", -1, -1)
    if showPower then
        missingHealth:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H + 1)
    else
        missingHealth:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 1)
    end
    missingHealth:SetWidth(FRAME_W * 0.28)
    missingHealth:SetColorTexture(0, 0, 0, 0.4)
    -- Exposed so the preview can tint the missing-health region when the
    -- health-bar indicator is in Tint mode with "Tint Entire Bar" enabled.
    container.missingHealth = missingHealth

    -- Power bar (only if enabled in settings)
    if showPower then
        local powerBg = mockFrame:CreateTexture(nil, "ARTWORK")
        powerBg:SetPoint("BOTTOMLEFT", 1, 1)
        powerBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 0)
        powerBg:SetHeight(POWER_H)
        powerBg:SetColorTexture(0.07, 0.07, 0.07, 1)

        local powerFill = mockFrame:CreateTexture(nil, "ARTWORK", nil, 1)
        powerFill:SetPoint("BOTTOMLEFT", 1, 1)
        powerFill:SetHeight(POWER_H)
        powerFill:SetWidth(FRAME_W * 0.85)
        powerFill:SetColorTexture(0.27, 0.53, 1, 0.9)

        -- Power bar top border
        local powerBorder = mockFrame:CreateTexture(nil, "ARTWORK", nil, 2)
        powerBorder:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, POWER_H)
        powerBorder:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H)
        powerBorder:SetHeight(1)
        powerBorder:SetColorTexture(0.2, 0.2, 0.2, 1)
    end

    -- Resolve fonts from settings
    local nameFontPath = DF:GetFontPath(frameDB.nameFont) or "Fonts\\FRIZQT__.TTF"
    local nameFontSize = frameDB.nameFontSize or 11
    local healthFontPath = DF:GetFontPath(frameDB.healthFont) or "Fonts\\FRIZQT__.TTF"
    local healthFontSize = frameDB.healthFontSize or 10

    -- Name text (uses user's font + anchor settings)
    local nameAnchor = frameDB.nameTextAnchor or "TOP"
    local nameOffX = frameDB.nameTextX or 0
    local nameOffY = frameDB.nameTextY or -10

    local nameText = mockFrame:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(nameFontPath, nameFontSize, "OUTLINE")
    nameText:SetPoint(nameAnchor, mockFrame, nameAnchor, nameOffX, nameOffY)
    nameText:SetText("Danders")
    nameText:SetTextColor(0.18, 0.80, 0.44, 1)
    container.nameText = nameText

    -- Health percentage (uses user's font + anchor settings)
    local healthAnchor = frameDB.healthTextAnchor or "CENTER"
    local healthOffX = frameDB.healthTextX or 0
    local healthOffY = frameDB.healthTextY or 4

    if frameDB.showHealthText ~= false then
        local hpText = mockFrame:CreateFontString(nil, "OVERLAY")
        hpText:SetFont(healthFontPath, healthFontSize, "OUTLINE")
        hpText:SetPoint(healthAnchor, mockFrame, healthAnchor, healthOffX, healthOffY)
        hpText:SetText("72%")
        hpText:SetTextColor(0.87, 0.87, 0.87, 1)
        container.hpText = hpText
    end

    -- Border overlay (used when border effect is active) — Stage 5.4: a
    -- DF.Border widget covering the mock frame, mirroring the runtime.
    container.borderOverlay = DF.Border:New(mockFrame, { frameLevelOffset = 5, layer = "OVERLAY" })

    -- Click background — no-op in new UI (was used to deselect aura in old tile view)
    local bgClick = CreateFrame("Button", nil, mockFrame)
    bgClick:SetAllPoints()
    bgClick:SetFrameLevel(mockFrame:GetFrameLevel() + 1)  -- Below dots and indicators
    bgClick:RegisterForClicks("LeftButtonUp")

    -- ========================================
    -- 9 ANCHOR POINT DOTS
    -- ========================================
    wipe(anchorDots)
    for anchorName, pos in pairs(ANCHOR_POSITIONS) do
        local dotFrame = CreateFrame("Frame", nil, mockFrame)
        dotFrame:SetSize(20, 20)
        dotFrame:SetFrameLevel(mockFrame:GetFrameLevel() + 10)

        -- Position the dot zone
        dotFrame:SetPoint(pos.ax, mockFrame, pos.ay, 0, 0)

        -- The visible dot
        local dc = GetThemeColor()
        local dot = dotFrame:CreateTexture(nil, "OVERLAY")
        dot:SetSize(6, 6)
        dot:SetPoint("CENTER", 0, 0)
        dot:SetColorTexture(dc.r, dc.g, dc.b, 0.3)
        dotFrame.dot = dot

        -- Hover zone (invisible button) -- also acts as drop target during drag
        local hoverBtn = CreateFrame("Button", nil, dotFrame)
        hoverBtn:SetAllPoints()
        local capturedAnchorName = anchorName
        hoverBtn:SetScript("OnEnter", function()
            if dragState.isDragging then
                -- Drag hover: enlarge and accent-color the dot
                local tc = GetThemeColor()
                dot:SetSize(14, 14)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.9)
                dragState.dropAnchor = capturedAnchorName
                -- Update hint to show target anchor
                if S.dragHintText and dragState.auraInfo then
                    S.dragHintText:SetText(format(L["Place %s at %s"], dragState.auraInfo.display, capturedAnchorName))
                end
            else
                local tc = GetThemeColor()
                dot:SetSize(10, 10)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.7)
            end
        end)
        hoverBtn:SetScript("OnLeave", function()
            if dragState.isDragging then
                -- Revert to drag-active state (not default)
                local tc = GetThemeColor()
                dot:SetSize(10, 10)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.5)
                dragState.dropAnchor = nil
                -- Revert hint to generic drag message
                if S.dragHintText and dragState.auraInfo then
                    S.dragHintText:SetText(format(L["Drop on an anchor point to place %s"], dragState.auraInfo.display))
                    S.dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
                end
            else
                local tc = GetThemeColor()
                dot:SetSize(6, 6)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.3)
            end
        end)

        dotFrame.anchorName = anchorName
        dotFrame:Hide()  -- Only visible during active drags
        anchorDots[anchorName] = dotFrame
    end

    -- Instructions with keyboard badge styling
    local instrRows = {
        { key = L["Click"],       desc = L["an indicator on the frame to expand its settings"] },
        { key = L["Drag"],        desc = L["a placed indicator to reposition it on the frame"] },
        { key = L["Right-click"], desc = L["a placed indicator to remove it from the frame"] },
    }

    local instrCount = #instrRows
    for i, row in ipairs(instrRows) do
        local rowBottomOffset = 10 + (instrCount - i) * 18

        -- Key badge background
        local badge = CreateFrame("Frame", nil, container, "BackdropTemplate")
        badge:SetHeight(13)
        badge:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 8, rowBottomOffset)
        ApplyBackdrop(badge, C_ELEMENT, C_BORDER)

        local keyText = badge:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        keyText:SetPoint("CENTER", 0, 0)
        keyText:SetText(row.key)
        keyText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        local keyWidth = keyText:GetStringWidth()
        badge:SetWidth(max(keyWidth + 10, 20))

        -- Description text (word-wrapped within container bounds)
        local descText = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descText:SetPoint("LEFT", badge, "RIGHT", 5, 0)
        descText:SetPoint("RIGHT", container, "RIGHT", -8, 0)
        descText:SetWordWrap(true)
        descText:SetJustifyH("LEFT")
        descText:SetText(row.desc)
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    end

    -- ========================================
    -- PREVIEW SCALE SLIDER
    -- ========================================
    local scaleSlider = GUI:CreateSlider(container, L["Preview Scale"], 0.75, 2.5, 0.05, adDB, "previewScale",
        -- callback (on release)
        function()
            local s = adDB.previewScale or 1.0
            mockFrame:SetScale(s)
        end,
        -- lightweightUpdate (during drag)
        function()
            local s = adDB.previewScale or 1.0
            mockFrame:SetScale(s)
        end
    )
    scaleSlider:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", -4, -4)
    scaleSlider:SetSize(220, 30)

    -- Drag-state hint text (shows contextual guidance during drag operations)
    S.dragHintText = container:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(S.dragHintText, 9, "OUTLINE")
    S.dragHintText:SetPoint("TOP", mockFrame, "BOTTOM", 0, -6)
    S.dragHintText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    S.dragHintText:SetText("")

    return container
end
P.CreateFramePreview = CreateFramePreview

-- ============================================================
-- TAB SYSTEM, SPELL PICKER & EFFECT CARDS (v4 redesign)
-- Functions for the new tabbed right panel, spell picker overlay,
-- and collapsible effect card rendering.
-- ============================================================

-- Forward declarations (mutually referencing functions)
-- (S.SwitchTab declared on the state table)
-- (S.BuildEffectsTab, S.BuildGlobalTab, S.BuildLayoutGroupsTab, S.BuildDebuffGroupsTab declared on the state table)
-- (S.CreateEffectCard declared on the state table)

-- (S.spellPickerBlockedIDs declared on the state table)
                                   -- cross-tab block; rebuilt per picker open)
local spellPickerBlockCache = {}   -- auraName -> bool memo over S.spellPickerBlockedIDs
                                   -- (wiped whenever the set is rebuilt) so blocked
                                   -- checks don't re-resolve identity per row bind

-- Cross-tab used check for one picker candidate: any of its identity IDs
-- (nil-spec identity on the Other tab — the naming contract's resolver —
-- else the spec identity) already tracked by the opposite pool.
local function IsCandidateCrossBlocked(auraName, spec)
    if not S.spellPickerBlockedIDs or not next(S.spellPickerBlockedIDs) then return false end
    local cached = spellPickerBlockCache[auraName]
    if cached ~= nil then return cached end
    local blocked = false
    local f = DF:BuildADIdentityFilters(IsOtherTab() and nil or spec, auraName)
    local map = f and f.includeSpellIDs
    if map then
        for id in pairs(map) do
            if S.spellPickerBlockedIDs[id] then blocked = true; break end
        end
    end
    spellPickerBlockCache[auraName] = blocked
    return blocked
end

-- Check if a specific aura has a frame-level effect of given type
local function HasFrameEffect(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    return auraCfg and auraCfg[typeKey] ~= nil
end

-- Clear all child frames and regions from the tab content area
local function ClearTabContent()
    if not S.tabContentFrame then return end
    local children = { S.tabContentFrame:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
        child:ClearAllPoints()
    end
    local regions = { S.tabContentFrame:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end
end

-- ── SHARED PICKER PLUMBING ──
-- Restore hook for the shared picker: fires on ANY close (back/ESC/
-- programmatic/ancestor hide). Brings the tab surfaces back and rebuilds
-- the active tab when an add landed while the picker stayed open.
local function ADPickerClosed()
    S.spellPickerBlockedIDs = nil -- recomputed on next open (memo wiped with it)
    if S.tabBar then S.tabBar:Show() end
    if S.tabScrollFrame then S.tabScrollFrame:Show() end
    if S.adPickerDirty then
        S.adPickerDirty = false
        S.SwitchTab(S.activeTab or "effects")
    end
end

-- Open prelude shared by the three AD contexts: fresh cross-tab block set
-- (the memo over it persists across row rebinds while the picker is up),
-- hide the tab surfaces the overlay replaces, and open the shared picker
-- over the right panel.
local function OpenADPicker(opts)
    S.spellPickerBlockedIDs = CrossPoolTrackedIDs()
    wipe(spellPickerBlockCache)
    S.adPickerDirty = false
    if S.tabBar then S.tabBar:Hide() end
    if S.tabScrollFrame then S.tabScrollFrame:Hide() end
    opts.parent = S.rightPanel
    opts.onClose = ADPickerClosed
    -- Empty record list on My Buffs = unsupported/undetected spec: keep
    -- the old picker's guidance instead of a bare "No results found".
    -- (Other Buffs records are the full SpellDB — never empty.)
    if not IsOtherTab() then
        opts.emptyText = L["No trackable spells found for this spec.\n\nYou can select a different spec using the dropdown above."]
    end
    S.adPickerHandle = DF.FilterRegistry:OpenSpellPicker(opts)
end

-- ── PICKER RECORDS ──
-- Shared-picker record list for the ACTIVE tab. My Buffs adapts the spec's
-- merged trackable list (curated Config entries + the SpellDB class pool +
-- class="ALL"); Other Buffs adapts the full SpellDB pool. includeAdHoc adds
-- configured "#<id>" auras (group + trigger pickers — never in the
-- trackable pool). Records carry the SpellDB-compatible shape the shared
-- picker renders (id / class / cats plus display and icon overrides — the
-- icon override keeps the static IconTextures talent-guard) plus
-- `auraName`, the stable AD config key the row handlers write.
local function BuildADPickerRecords(includeAdHoc)
    local isOther = IsOtherTab()
    local spec = (not isOther) and ResolveSpec() or nil
    local auras
    if isOther then
        auras = Adapter and Adapter.GetAllTrackableAuras and Adapter:GetAllTrackableAuras()
    else
        auras = spec and Adapter and Adapter:GetTrackableAuras(spec)
    end
    if not auras then return {} end
    if includeAdHoc then
        auras = WithConfiguredAdHocAuras(auras, spec)
    end
    local specInfo = spec and DF.AuraDesigner.SpecInfo[spec]
    local lockClass = specInfo and specInfo.class
    local R = DF.FilterRegistry
    local tooltipOverrides = DF.AuraDesigner.TooltipSpellIDs
    local specIDs = spec and DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
    local out = {}
    for _, ai in ipairs(auras) do
        -- Tooltip/canonical id: override table, else the spec whitelist,
        -- else the pool entry's canonical id (same chain as the old cards)
        local id = (tooltipOverrides and tooltipOverrides[ai.name])
            or (specIDs and specIDs[ai.name]) or ai.spellID
        if type(id) == "table" then id = id[1] end -- rare multi-id entries
        local rec = R and R.ByID and id and R.ByID[id]
        out[#out + 1] = {
            id = id or 0,
            class = ai.class or lockClass or "ALL",
            cats = rec and rec.cats or nil,
            display = ai.display or ai.name,
            icon = GetAuraIcon(spec, ai.name),
            -- Letter/colour-swatch fallback for auras whose icon texture
            -- doesn't resolve (the old card fallback)
            iconColor = type(ai.color) == "table" and ai.color or nil,
            auraName = ai.name,
        }
    end
    return out
end

-- Cross-tab block caption for one picker record (B2): a spell tracked by
-- the OPPOSITE pool renders dimmed, captioned with the tab it lives in,
-- and every add path is blocked.
local function ADCrossBlockText(rec)
    if IsCandidateCrossBlocked(rec.auraName, ResolveSpec()) then
        return IsOtherTab() and L["In My Buffs"] or L["In Any Buff"]
    end
    return nil
end

-- ── SWITCH TAB ──
S.SwitchTab = function(tabKey)
    -- Effects is frosted on the Debuffs tab (C2: category groups have no
    -- placed indicators) — coerce to Layout Groups (belt-and-braces; the
    -- sub-tab button is also frosted).
    if tabKey == "effects" and IsDebuffTab() then
        tabKey = "layout"
    end
    -- Preserve scroll position when refreshing the same tab
    local prevTab = S.activeTab
    local savedScroll = 0
    if tabKey == prevTab and S.tabScrollFrame then
        savedScroll = S.tabScrollFrame:GetVerticalScroll()
    end

    S.activeTab = tabKey
    -- This switch rebuilds the tab anyway — skip the close hook's own
    -- dirty rebuild so the tab isn't built twice.
    S.adPickerDirty = false
    CloseADPicker()
    if GUI then GUI:CloseAllMenus() end   -- an open dropdown (e.g. spec) must not outlive the tab

    for key, btn in pairs(tabButtons) do
        btn:SetActive(key == tabKey)  -- underline + accent/dim label (tab mode)
    end

    ClearTabContent()

    if tabKey == "effects" then
        S.BuildEffectsTab()
    elseif tabKey == "layout" then
        -- The Debuffs tab's Layout Groups list shows ONLY debuff category
        -- groups; My Buffs / Other Buffs each build their OWN pool's
        -- member+filter groups (S.BuildLayoutGroupsTab is pool-routed).
        if IsDebuffTab() then
            S.BuildDebuffGroupsTab()
        else
            S.BuildLayoutGroupsTab()
        end
    elseif tabKey == "global" then
        S.BuildGlobalTab()
    end

    if S.tabScrollFrame then
        if tabKey == prevTab then
            -- Clamp to new max scroll range (content may have changed height)
            local maxScroll = S.tabScrollFrame:GetVerticalScrollRange()
            S.tabScrollFrame:SetVerticalScroll(min(savedScroll, maxScroll))
        else
            S.tabScrollFrame:SetVerticalScroll(0)
        end
    end
end

-- ── MAIN POOL TAB SWITCH (B2/C2: My Buffs / Debuffs / Other Buffs) ──

-- Grey/restore the sub-tabs: frosted (SetDisabled — stays mouse-enabled so
-- the tooltip can explain why; OnClick early-outs on dfDisabled). Effects
-- frosts on the Debuffs tab (category groups have no placed indicators).
-- Layout Groups is live on BOTH buff tabs (the Other tab hosts the flat
-- other-pool group store) — it never frosts anymore.
local function UpdateLayoutTabState()
    local layoutBtn = tabButtons and tabButtons.layout
    if layoutBtn and layoutBtn.SetDisabled then
        layoutBtn:SetDisabled(false)
    end
    local effectsBtn = tabButtons and tabButtons.effects
    if effectsBtn and effectsBtn.SetDisabled then
        effectsBtn:SetDisabled(IsDebuffTab())
    end
end
P.UpdateLayoutTabState = UpdateLayoutTabState

-- Grey the spec dropdown + swap its opener text on the Other and Debuffs
-- tabs (both pools are shared across specs); restore the live spec text on
-- My Buffs.
local function UpdateSpecDropdownState()
    if not S.specDropdown then return end
    if IsOtherTab() or IsDebuffTab() then
        if S.specDropdown.SetDisplayOverride then
            S.specDropdown:SetDisplayOverride(L["— (shared across specs)"])
        end
        S.specDropdown:SetEnabled(false)
    else
        S.specDropdown:SetEnabled(true)
        if S.specDropdown.SetDisplayOverride then
            S.specDropdown:SetDisplayOverride(nil)
        end
        if S.specDropdownUpdate then S.specDropdownUpdate() end
    end
end
P.UpdateSpecDropdownState = UpdateSpecDropdownState

local function SetMainTab(tabKey)
    if S.activeBuffTab == tabKey then return end
    S.activeBuffTab = tabKey
    -- Editor keys are pool-prefixed (B1) so cards can't collide across tabs,
    -- but mirror the spec dropdown's behavior: a pool switch collapses all
    -- expanded cards (wipe, not per-tab preservation).
    wipe(expandedCards)
    -- The shared picker captures its pool/effect at open time — never let
    -- it survive a pool switch.
    CloseADPicker()
    if GUI then GUI:CloseAllMenus() end   -- an open dropdown (e.g. spec) must not outlive the tab
    for key, btn in pairs(mainTabButtons) do
        btn:SetActive(key == tabKey)
    end
    UpdateSpecDropdownState()
    UpdateLayoutTabState()
    -- Effects is frosted on the Debuffs tab, so land on Layout Groups (the
    -- tab's primary surface). Layout Groups is live on both buff tabs — no
    -- coercion needed when arriving there.
    if S.activeBuffTab == "debuffs" and S.activeTab == "effects" then
        S.activeTab = "layout"
    end
    -- One entry point swaps every surface: RefreshPage → S.SwitchTab(S.activeTab)
    -- (list, chips, add menu) + RefreshPlacedIndicators/RefreshPreviewEffects
    -- (preview, drag targets) — all pool-routed through CurrentAuraPool.
    DF:AuraDesigner_RefreshPage()
end
P.SetMainTab = SetMainTab

-- ── ADD FROM PICKER (shared path) ──
-- What accepting a spell in the picker DOES: create the placed indicator
-- instance (or the frame-level type config, mode = "frame") and pre-expand
-- its effect card. Used by both the row handler and add-by-ID so the two
-- entry points can never drift apart.
local function AddPickedSpell(auraName, typeKey, mode)
    -- Card keys embed the B1 pool prefix in the name segment
    -- ("placed:other:<name>#<id>" / "frame:<type>:other:<name>").
    if mode == "placed" then
        local instance = CreateIndicatorInstance(auraName, typeKey)
        if instance then
            expandedCards["placed:" .. PoolKeyPrefix() .. auraName .. "#" .. instance.id] = true
        end
    else
        EnsureTypeConfig(auraName, typeKey)
        expandedCards["frame:" .. typeKey .. ":" .. PoolKeyPrefix() .. auraName] = true
    end
    -- Structural change: drive the LIVE frames, not just the editor. The callers only run
    -- RefreshPlacedIndicators / RefreshPreviewEffects (editor chips + preview canvas), so
    -- without this a freshly added indicator never builds its live container until some other
    -- action (move / eye toggle / reload) fires ForceRefreshAllFrames. Mirrors AddSpellToGroup.
    DF:InvalidateAuraLayout()
    DF:UpdateAllFrames()
    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
    end
end

-- ── ADD TO LAYOUT GROUP ("group" picker context) ──
-- One click on a row's Icon/Square button (or the ID row's, for add-by-ID):
-- create a NEW placed indicator of that type and enrol it in the target group.
-- The picker stays open for multi-add, and the same spell can be added again —
-- every add mints a fresh indicator id, so AddGroupMember's (auraName,
-- indicatorID) dedup never blocks it. skipEcho lets add-by-ID substitute its
-- own unknown-ID echo. Refresh chain mirrors the group card's member ✕.
local function AddSpellToGroup(groupID, auraName, display, typeKey, skipEcho, picker)
    if not groupID then return end
    local instance = CreateIndicatorInstance(auraName, typeKey)
    if not instance then return end
    AddGroupMember(groupID, auraName, instance.id)
    S.adPickerDirty = true  -- layout tab behind the picker is stale; rebuilt on close
    if not skipEcho and picker then
        local typeLabel = S.PLACED_TYPE_LABELS[typeKey] or typeKey
        picker:Echo(format(L["Added %s."],
            format("%s (%s)", display or auraName, typeLabel)))
    end
    RefreshPlacedIndicators()
    -- Structural change: same full refresh as the member ✕
    -- (new indicator container + group positions + buff-row dedup).
    DF:InvalidateAuraLayout()
    DF:UpdateAllFrames()
    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
    end
end

-- ── ADD BY ID (shared picker ID row) ──
-- Snap known ids to their pool/curated record (then behave exactly like
-- clicking that spell's row — same AddPickedSpell / AddSpellToGroup paths);
-- unknown ids become an ad-hoc "#<id>" aura whose key IS its identity
-- (S.CleanupAdHocAura drops the config again once its last effect is
-- removed). The picker stays open (echo confirms), so several ids can be
-- added in a row. The shared picker has already validated the digits and
-- normalized leading zeros; idText is that validated digit STRING. Returns
-- truthy when the add landed (the picker clears its ID box on that).
local function ADAddByID(idNum, idText, picker, mode, typeKey, groupID)
    local isOther = IsOtherTab()
    local spec = ResolveSpec()
    -- The Other Buffs pool is spec-independent — no spec required there.
    if not spec and not isOther then return end

    -- Snap. My Buffs: the spec's curated tables first (alt ids included),
    -- then the SpellDB (R.ByID indexes canonical + alt ids), else ad-hoc.
    -- Other Buffs: SpellDB ONLY — the B1 naming contract (other-pool keys
    -- are SpellDB rec.n or ad-hoc "#<id>"; curated internal names don't
    -- resolve with a nil spec).
    local auraName
    if not isOther then
        local alts = DF.AuraDesigner.AlternateSpellIDs and DF.AuraDesigner.AlternateSpellIDs[spec]
        if alts and alts[idNum] then auraName = alts[idNum] end
        if not auraName then
            local specIDs = DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
            if specIDs then
                for name, id in pairs(specIDs) do
                    if id == idNum then auraName = name; break end
                    if type(id) == "table" then  -- rare multi-id entries
                        for _, sub in ipairs(id) do
                            if sub == idNum then auraName = name; break end
                        end
                        if auraName then break end
                    end
                end
            end
        end
    end
    if not auraName then
        local R = DF.FilterRegistry
        local rec = R and R.ByID and R.ByID[idNum]
        if rec then auraName = rec.n end
    end

    local isAdHoc = not auraName
    -- Key from the validated TEXT, not tonumber output — number formatting
    -- must never leak into config keys (AdHocSpellID parses "^#(%d+)$").
    if isAdHoc then auraName = "#" .. idText end

    -- Cross-tab block (B2): the spell — snapped name's FULL identity set,
    -- or the raw id for ad-hoc — is already tracked by the OPPOSITE pool.
    -- Checked before the group branch so group adds are blocked too.
    local crossBlocked = false
    if S.spellPickerBlockedIDs and next(S.spellPickerBlockedIDs) then
        if S.spellPickerBlockedIDs[idNum] then
            crossBlocked = true
        elseif not isAdHoc then
            crossBlocked = IsCandidateCrossBlocked(auraName, spec)
        end
    end
    if crossBlocked then
        picker:Echo(isOther and L["Already tracked in My Buffs."] or L["Already tracked in Any Buff."])
        return
    end

    -- Display name: the trackable pool entry when it has one (curated
    -- display or localized SpellDB name), else the raw key.
    local display = auraName
    if not isAdHoc then
        if isOther then
            display = OtherPoolDisplayName(auraName)
        else
            local trackable = Adapter and Adapter:GetTrackableAuras(spec)
            if trackable then
                for _, info in ipairs(trackable) do
                    if info.name == auraName then display = info.display or auraName; break end
                end
            end
        end
    end

    -- Group context: no already-used gate (a spell can hold several
    -- indicators in one group). AddSpellToGroup echoes and refreshes.
    if mode == "group" then
        AddSpellToGroup(groupID, auraName, display, typeKey or "icon", isAdHoc, picker)
        if isAdHoc then
            picker:Echo(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
            picker:RefreshRecords()  -- the new ad-hoc aura gets a row of its own
        end
        return true
    end

    local alreadyUsed
    if mode == "placed" then
        alreadyUsed = IsAuraTypePlaced(auraName, typeKey)
    else
        alreadyUsed = HasFrameEffect(auraName, typeKey)
    end
    if alreadyUsed then
        picker:Echo(L["Already added."])
        return
    end

    AddPickedSpell(auraName, typeKey, mode)
    S.adPickerDirty = true
    if isAdHoc then
        picker:Echo(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
    else
        picker:Echo(format(L["Added %s."], display))
    end
    picker:Refresh()             -- the row flips to its blocked state
    RefreshPlacedIndicators()    -- live preview updates behind the picker
    RefreshPreviewEffects()
    return true
end

-- ── OPEN: ADD INDICATOR (placed + frame contexts) ──
-- typeKey: "icon"|"square"|"bar" (placed) or "border"|"healthbar"|etc.
-- (frame); mode: "placed" or "frame". Single-pick — choosing a spell
-- creates the indicator (or frame-level type config), closes the picker
-- and lands on its expanded effect card. My Buffs locks the picker to the
-- resolved spec's class (class dropdown hidden, records limited to the
-- class + "ALL"); Other Buffs offers the full database with both filters.
local function OpenIndicatorPicker(typeKey, mode)
    local isOther = IsOtherTab()
    local spec = (not isOther) and ResolveSpec() or nil
    local specInfo = spec and DF.AuraDesigner.SpecInfo[spec]
    local badgeColor = BADGE_COLORS[typeKey] or BADGE_COLORS.icon
    local title
    if mode == "frame" then
        title = format(L["Select trigger for %s"], S.FRAME_LEVEL_LABELS[typeKey] or typeKey)
    else
        title = L["Select a spell"]
    end
    OpenADPicker({
        title = title,
        subtitle = S.PLACED_TYPE_LABELS[typeKey] or S.FRAME_LEVEL_LABELS[typeKey] or typeKey,
        subtitleColor = badgeColor,
        records = function() return BuildADPickerRecords(false) end,
        classLock = (not isOther) and specInfo and specInfo.class or nil,
        isBlocked = function(rec)
            local cross = ADCrossBlockText(rec)
            if cross then return cross end
            if mode == "placed" then
                if IsAuraTypePlaced(rec.auraName, typeKey) then return L["Placed"] end
            elseif HasFrameEffect(rec.auraName, typeKey) then
                return L["Active"]
            end
            return nil
        end,
        rowActions = {
            {
                label = L["Add"], -- labels the ID-row button; rows are click-to-add
                handler = function(rec, _, picker)
                    AddPickedSpell(rec.auraName, typeKey, mode)
                    picker:Close()
                    S.SwitchTab("effects")
                    RefreshPlacedIndicators()
                    RefreshPreviewEffects()
                end,
            },
        },
        allowAddByID = true,
        onAddByID = function(idNum, _, picker, idText)
            return ADAddByID(idNum, idText, picker, mode, typeKey, nil)
        end,
    })
end

-- ── OPEN: ADD TO LAYOUT GROUP ──
-- Every row carries Icon / Square buttons that create the indicator and
-- enrol it in the target group in one click (the picker stays open for
-- adding several in a row); the ID row gets the same two buttons, Enter
-- defaulting to Icon. Records include the pool's configured ad-hoc
-- "#<id>" auras — the old picker offered them too.
local function OpenGroupSpellPicker(groupID)
    local isOther = IsOtherTab()
    local spec = (not isOther) and ResolveSpec() or nil
    local specInfo = spec and DF.AuraDesigner.SpecInfo[spec]
    local grp = groupID and GetLayoutGroupByID(groupID)
    OpenADPicker({
        title = L["Select a spell"],
        subtitle = grp and grp.name or "",
        subtitleColor = GetThemeColor(),
        records = function() return BuildADPickerRecords(true) end,
        classLock = (not isOther) and specInfo and specInfo.class or nil,
        -- Duplicates are allowed (each add is its own indicator instance),
        -- so only the cross-tab block dims a row.
        isBlocked = ADCrossBlockText,
        rowActions = {
            {
                label = S.PLACED_TYPE_LABELS.icon or "Icon",
                color = BADGE_COLORS.icon,
                typeKey = "icon",
                handler = function(rec, _, picker)
                    AddSpellToGroup(groupID, rec.auraName, rec.display, "icon", false, picker)
                end,
            },
            {
                label = S.PLACED_TYPE_LABELS.square or "Square",
                color = BADGE_COLORS.square,
                typeKey = "square",
                handler = function(rec, _, picker)
                    AddSpellToGroup(groupID, rec.auraName, rec.display, "square", false, picker)
                end,
            },
        },
        allowAddByID = true,
        onAddByID = function(idNum, action, picker, idText)
            return ADAddByID(idNum, idText, picker, "group", (action and action.typeKey) or "icon", groupID)
        end,
    })
end
P.OpenGroupSpellPicker = OpenGroupSpellPicker

-- ── CREATE EFFECT CARD ──
-- Creates a collapsible card for one effect in the effects list.
-- Returns the new yPos after the card.
S.CreateEffectCard = function(parent, yPos, effect)
    local isPlaced = (effect.source == "placed")
    -- B1 key scheme: the pool prefix rides the NAME segment, so the two
    -- pools' expandedCards entries can never collide.
    local keyPrefix = PoolKeyPrefix()
    local cardKey
    if isPlaced then
        cardKey = "placed:" .. keyPrefix .. effect.auraName .. "#" .. effect.indicatorID
    else
        cardKey = "frame:" .. effect.typeKey .. ":" .. keyPrefix .. effect.auraName
    end

    local isExpanded = expandedCards[cardKey] or false

    -- ── CARD + HEADER ──
    local card, header, chevron = CreateCardShell(parent, {
        yPos        = yPos,
        expanded    = isExpanded,
        borderColor = {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5},
    })

    -- Spell icon (small, before type badge). Other-pool records resolve
    -- icon/identity spec-independently (nil spec → ad-hoc / SpellDB fallback).
    local spec = IsOtherTab() and nil or ResolveSpec()
    local iconTex = GetAuraIcon(spec, effect.auraName)
    local spellIcon = header:CreateTexture(nil, "ARTWORK")
    spellIcon:SetSize(20, 20)
    spellIcon:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
    if iconTex then
        spellIcon:SetTexture(iconTex)
        spellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        -- Color swatch fallback using aura color
        local trackable3 = spec and Adapter and Adapter:GetTrackableAuras(spec)
        local auraColor = nil
        if trackable3 then
            for _, ai in ipairs(trackable3) do
                if ai.name == effect.auraName then auraColor = ai.color; break end
            end
        end
        if auraColor then
            spellIcon:SetColorTexture(auraColor[1] * 0.5, auraColor[2] * 0.5, auraColor[3] * 0.5, 1)
        else
            spellIcon:SetColorTexture(0.25, 0.25, 0.25, 1)
        end
    end

    -- Type badge
    local badgeColor = BADGE_COLORS[effect.typeKey] or BADGE_COLORS.icon
    local typeLabel = isPlaced
        and (S.PLACED_TYPE_LABELS[effect.typeKey] or effect.typeKey)
        or (S.FRAME_LEVEL_LABELS[effect.typeKey] or effect.typeKey)

    local badgeBg = CreateFrame("Frame", nil, header, "BackdropTemplate")
    badgeBg:SetHeight(16)
    badgeBg:SetPoint("LEFT", spellIcon, "RIGHT", 4, 0)
    ApplyBackdrop(badgeBg,
        {r = badgeColor.r * 0.20, g = badgeColor.g * 0.20, b = badgeColor.b * 0.20, a = 1},
        {r = badgeColor.r * 0.45, g = badgeColor.g * 0.45, b = badgeColor.b * 0.45, a = 0.8})

    local badgeText = badgeBg:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(badgeText, 8, "OUTLINE")
    badgeText:SetPoint("CENTER", 0, 0)
    badgeText:SetText(typeLabel)
    badgeText:SetTextColor(1, 1, 1)
    badgeBg:SetWidth(max(badgeText:GetStringWidth() + 12, 32))

    -- Warning badge for auras with API-level tracking limitations
    -- (positioned to the right of the type badge)
    local warnKey = GetAuraWarningKey(spec, effect.auraName)
    AttachWarningBadge(header, warnKey, {
        point = "LEFT",
        relativeTo = badgeBg,
        relativePoint = "RIGHT",
        offsetX = 4,
        offsetY = 0,
        size = 16,
    })

    -- Aura name + anchor/trigger/group info
    local infoStr = effect.displayName
    local indicatorGroup = nil  -- layout group this indicator belongs to
    if isPlaced then
        indicatorGroup = GetIndicatorLayoutGroup(effect.auraName, effect.indicatorID)
        if indicatorGroup then
            infoStr = infoStr .. "  -  " .. indicatorGroup.name
        elseif effect.anchor then
            infoStr = infoStr .. "  -  " .. (OPTS.ANCHOR_OPTIONS[effect.anchor] or effect.anchor)
        end
    else
        -- Show trigger count for frame-level effects
        local triggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
        if #triggers > 1 then
            -- No "(AND)" suffix: the operator toggle is gone (12.1 cannot evaluate
            -- triggers together read-free), so multiple triggers always mean ANY/OR.
            infoStr = infoStr .. "  -  " .. format(L["+%d triggers"], #triggers - 1)
        end
    end
    -- Other Buffs: surface the per-effect Others Only state on the collapsed
    -- header (prototype's "Others only" chip, as a text suffix).
    if IsOtherTab() and effect.config and effect.config.othersOnly then
        infoStr = infoStr .. "  -  " .. L["Others Only"]
    end
    local infoText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    if warnKey and header.dfWarningBadge and header.dfWarningBadge:IsShown() then
        infoText:SetPoint("LEFT", header.dfWarningBadge, "RIGHT", 6, 0)
    else
        infoText:SetPoint("LEFT", badgeBg, "RIGHT", 6, 0)
    end
    -- Right inset clears the action icons: eye only (grouped) or eye + ✕.
    infoText:SetPoint("RIGHT", header, "RIGHT", indicatorGroup and -30 or -52, 0)
    infoText:SetMaxLines(1)
    infoText:SetText(infoStr)
    if indicatorGroup then
        -- Use dimmed text for grouped indicators — they're managed by the group
        infoText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    else
        infoText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    end

    -- Delete button — hidden for grouped indicators (managed by layout group)
    local delBtn
    if not indicatorGroup then
        delBtn = GUI:CreateCloseButton(header, {
            size = 22,
            onClick = function()
                if isPlaced then
                    RemoveIndicatorInstance(effect.auraName, effect.indicatorID)
                else
                    local auraCfg = CurrentAuraPool()[effect.auraName]
                    if auraCfg then auraCfg[effect.typeKey] = nil end
                    S.CleanupAdHocAura(effect.auraName)  -- drop emptied ad-hoc "#<id>" entries
                end
                expandedCards[cardKey] = nil
                S.SwitchTab("effects")
                RefreshPlacedIndicators()
                RefreshPreviewEffects()
                -- Structural change: the container must rebuild AND the buff-row
                -- dedup union shrinks (deleted = no longer tracked), so run the
                -- full refresh path (mirror the eye toggle) — without this the
                -- deleted indicator's buff-row icon stays suppressed until an
                -- unrelated rebuild.
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end,
        })
        delBtn:SetPoint("RIGHT", -4, 0)
        delBtn:SetFrameLevel(header:GetFrameLevel() + 2)
    end

    -- Eye icon (visibility toggle) — left of the ✕; grouped indicators keep it
    -- even though their ✕ is hidden. Asset + toggle idiom mirror Text Designer's
    -- eye (TextDesigner/Options.lua): visibility / visibility_off from
    -- Media/Icons, bright when shown, dim when hidden, hover brighten.
    -- State lives on the raw config table: enabled == false is hidden;
    -- nil/true (legacy records) is shown.
    do
        local cfgTable = effect.config
        local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
        local eyeBtn = DF.GUI:CreateGlyphButton(header, { size = 18 })
        if delBtn then
            eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        else
            eyeBtn:SetPoint("RIGHT", header, "RIGHT", -6, 0)
        end
        local function shown() return not cfgTable or cfgTable.enabled ~= false end
        -- SetGlyph makes the state colour the new REST colour, so OnLeave
        -- restores the state; hover is suppressed while hidden.
        local function updateEyeIcon()
            if shown() then
                eyeBtn:SetGlyph(mediaPath .. "visibility", { 0.95, 0.95, 0.95 })
            else
                eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.45, 0.45, 0.45 })
            end
            eyeBtn:SetGlyphHover(shown())
        end
        updateEyeIcon()
        eyeBtn:RegisterForClicks("LeftButtonUp")
        eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
        eyeBtn:SetScript("OnClick", function()
            if not cfgTable then return end
            cfgTable.enabled = (cfgTable.enabled == false) and true or false
            updateEyeIcon()
            -- Sound rides the same flag as its "Enable Sound Alert" checkbox —
            -- stop a playing alert immediately when hidden (mirror that checkbox).
            if effect.typeKey == "sound" and cfgTable.enabled == false
                and DF.AuraDesigner.SoundEngine then
                DF.AuraDesigner.SoundEngine:StopAura(effect.auraName)
            end
            -- Structural change: the factory must tear down / stand up the
            -- container and the buff-row dedup union changes (hidden = not
            -- tracked), so run the full refresh path (mirror the enable toggle).
            S.SwitchTab("effects")
            RefreshPlacedIndicators()
            RefreshPreviewEffects()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
        end)

        -- Hidden rows dim (name/icon), like Text Designer's disabled elements
        if not shown() then
            spellIcon:SetAlpha(0.4)
            infoText:SetAlpha(0.5)
        end
    end

    -- Header click → toggle expansion
    header:SetScript("OnClick", function()
        expandedCards[cardKey] = not expandedCards[cardKey]
        S.SwitchTab("effects")
    end)
    header:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    header:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)

    local totalCardH = 30

    -- ── BODY (only when expanded) ──
    if isExpanded then
        local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
        body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
        body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
        ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

        -- Create the appropriate proxy
        local proxy
        if isPlaced then
            proxy = CreateInstanceProxy(effect.auraName, effect.indicatorID)
        else
            proxy = CreateProxy(effect.auraName, effect.typeKey)
        end

        -- Build type-specific widgets (derive width from parent scroll frame)
        local bodyWidth = (S.tabContentFrame and S.tabContentFrame:GetWidth() or 260) - 24
        if bodyWidth < 100 then bodyWidth = 240 end

        local triggersH = 0

        -- ── TRIGGER TAGS (frame-level effects only) ──
        if not isPlaced then
            local triggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
            local trigContainer = CreateFrame("Frame", nil, body)
            trigContainer:SetPoint("TOPLEFT", 8, -12)
            trigContainer:SetPoint("RIGHT", body, "RIGHT", -8, 0)

            local trigLabel = trigContainer:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(trigLabel, 9, "")
            trigLabel:SetPoint("TOPLEFT", 0, 0)
            trigLabel:SetText(L["TRIGGERED BY"])
            trigLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

            -- AND/OR operator toggle (only shown with 2+ triggers)
            -- (No multi-trigger ALL/ANY operator button: evaluating every trigger together
            --  needs a read the 12.1 aura system cannot do for secret-anchored triggers, so
            --  it was permanently frosted. Removed 2026-07-25 -- triggerOperator was never
            --  read by the render path either, only by this editor's own label, so the
            --  toggle changed nothing. Triggers combine as ANY/OR. The tags stay editable.)

            -- Build display name lookup for tags. Other-pool trigger names are
            -- SpellDB names / ad-hoc keys — resolved live per tag below.
            local isOtherCard = IsOtherTab()
            local spec = (not isOtherCard) and ResolveSpec() or nil
            local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
            local displayNames = {}
            if trackable then
                for _, info in ipairs(trackable) do
                    displayNames[info.name] = info.display
                end
            end
            if isOtherCard then
                setmetatable(displayNames, { __index = function(_, name)
                    return OtherPoolDisplayName(name)
                end })
            end

            -- Tag flow layout
            local TAG_H = 20
            local TAG_GAP = 4
            local TAG_ROW_GAP = 3
            local tagX, tagY = 0, -(14 + 6)  -- below label
            local canRemove = #triggers > 1

            for ti, trigName in ipairs(triggers) do
                local tagFrame = CreateFrame("Frame", nil, trigContainer, "BackdropTemplate")
                tagFrame:SetHeight(TAG_H)

                local tagText = tagFrame:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(tagText, 9, "")
                tagText:SetPoint("LEFT", 6, 0)
                tagText:SetText(displayNames[trigName] or trigName)
                tagText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                local tagW = tagText:GetStringWidth() + 12
                if canRemove then tagW = tagW + 16 end  -- room for × button
                tagW = max(tagW, 40)

                -- Wrap to next row if needed
                local containerW = trigContainer:GetWidth()
                if containerW < 50 then containerW = bodyWidth - 16 end
                if tagX > 0 and (tagX + tagW) > containerW then
                    tagX = 0
                    tagY = tagY - (TAG_H + TAG_ROW_GAP)
                end

                tagFrame:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
                tagFrame:SetWidth(tagW)
                ApplyBackdrop(tagFrame,
                    {r = 0.14, g = 0.14, b = 0.17, a = 1},
                    {r = 0.30, g = 0.30, b = 0.35, a = 0.8})

                -- Remove × button on each tag (unless it's the last one)
                if canRemove then
                    local capturedTrigName = trigName
                    -- Shared red-at-rest "×" (tone="danger") on each removable tag.
                    local removeBtn = DF.GUI:CreateCloseButton(tagFrame, {
                        size = 14,
                        tone = "danger",
                        onClick = function()
                            RemoveFrameEffectTrigger(effect.auraName, effect.typeKey, capturedTrigName)
                            S.SwitchTab("effects")
                            RefreshPreviewEffects()
                        end,
                    })
                    removeBtn:SetPoint("RIGHT", -2, 0)
                end

                tagX = tagX + tagW + TAG_GAP
            end

            -- "+ Add Trigger" button
            local addTrigW = 80
            if tagX > 0 and (tagX + addTrigW) > (bodyWidth - 16) then
                tagX = 0
                tagY = tagY - (TAG_H + TAG_ROW_GAP)
            end
            local addTrigBtn = CreateFrame("Button", nil, trigContainer, "BackdropTemplate")
            addTrigBtn:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
            GUI:StyleButton(addTrigBtn, { width = addTrigW, height = TAG_H, primary = true, accent = { r = 0.25, g = 0.40, b = 0.25 }, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add Trigger"] })
            GUI:SetSettingsFont(addTrigBtn.Text, 9, "")
            addTrigBtn.Text:SetTextColor(0.5, 0.8, 0.5)
            addTrigBtn.Icon:SetVertexColor(0.5, 0.8, 0.5)

            -- Trigger picker: the shared spell database picker, single-pick.
            -- My Buffs locks it to the resolved spec's class; Other Buffs
            -- offers the full database (the old plain dropdown restricted
            -- Other-tab triggers to already-configured auras only because
            -- the full DB was unusable without search/filters — the shared
            -- picker has both, so the restriction is lifted). Records also
            -- include the pool's configured ad-hoc "#<id>" auras. Rows
            -- already in the effect's trigger list render with the dimmed
            -- check ("already added").
            addTrigBtn:SetScript("OnClick", function()
                -- Pin the pool at OPEN time (pool pinning carried over from
                -- the old floating dropdown): a pick must keep writing the
                -- trigger into the pool this card's record lives in, no
                -- matter how the surrounding UI state moves while the
                -- picker is up (the record exists, so the read accessor
                -- returns the real table, never EMPTY_POOL).
                local capturedPool = CurrentAuraPool()
                local isOtherTrig = IsOtherTab()
                local trigSpec = (not isOtherTrig) and ResolveSpec() or nil
                local trigSpecInfo = trigSpec and DF.AuraDesigner.SpecInfo[trigSpec]

                local currentTriggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
                local trigLookup = {}
                for _, t in ipairs(currentTriggers) do trigLookup[t] = true end

                OpenADPicker({
                    title = format(L["Select trigger for %s"], S.FRAME_LEVEL_LABELS[effect.typeKey] or effect.typeKey),
                    subtitle = effect.displayName,
                    records = function() return BuildADPickerRecords(true) end,
                    classLock = (not isOtherTrig) and trigSpecInfo and trigSpecInfo.class or nil,
                    isBlocked = function(rec)
                        return trigLookup[rec.auraName] and true or nil
                    end,
                    rowActions = {
                        {
                            handler = function(rec, _, picker)
                                AddFrameEffectTrigger(effect.auraName, effect.typeKey, rec.auraName, capturedPool)
                                picker:Close()
                                S.SwitchTab("effects")
                                RefreshPreviewEffects()
                            end,
                        },
                    },
                })
            end)

            triggersH = -(tagY) + TAG_H + 8  -- total height of trigger section
            trigContainer:SetHeight(triggersH)

            -- Border mode toggle (border effects only)
            if effect.typeKey == "border" then
                local auraCfgBM = CurrentAuraPool()[effect.auraName]
                local typeCfgBM = auraCfgBM and auraCfgBM[effect.typeKey]
                local isCustom = typeCfgBM and typeCfgBM.borderMode == "custom"

                local bmContainer = CreateFrame("Frame", nil, body)
                bmContainer:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(triggersH + 10))
                bmContainer:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                bmContainer:SetHeight(26)

                local bmLabel = bmContainer:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(bmLabel, 9, "")
                bmLabel:SetPoint("LEFT", 0, 0)
                bmLabel:SetText(L["Border Mode:"])
                bmLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

                -- Shared button
                local sharedBtn = CreateFrame("Button", nil, bmContainer, "BackdropTemplate")
                sharedBtn:SetPoint("LEFT", bmLabel, "RIGHT", 6, 0)

                local sharedText = sharedBtn:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(sharedText, 9, "")
                sharedText:SetPoint("CENTER", 0, 0)
                sharedText:SetText(L["Shared"])
                local sharedW = sharedText:GetStringWidth() + 16
                if sharedW < 50 then sharedW = 50 end
                -- Shared styler: rest + accent-wash hover + SetActive selection state.
                -- Keep the manual (small) label; size to the computed text width.
                GUI:StyleButton(sharedBtn, { width = sharedW, height = 20 })

                -- Custom button
                local customBtn = CreateFrame("Button", nil, bmContainer, "BackdropTemplate")
                customBtn:SetPoint("LEFT", sharedBtn, "RIGHT", 4, 0)

                local customText = customBtn:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(customText, 9, "")
                customText:SetPoint("CENTER", 0, 0)
                customText:SetText(L["Custom"])
                local customW = customText:GetStringWidth() + 16
                if customW < 50 then customW = 50 end
                GUI:StyleButton(customBtn, { width = customW, height = 20 })

                -- Drive the selection state via the shared styler's SetActive (active =
                -- toned accent border + subtle accent fill). Keep a bright/dim label cue.
                local function StyleBorderModeButtons(customActive)
                    sharedBtn:SetActive(not customActive)
                    customBtn:SetActive(customActive)
                    if customActive then
                        customText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                        sharedText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                    else
                        sharedText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                        customText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                    end
                end
                StyleBorderModeButtons(isCustom)

                sharedBtn:SetScript("OnClick", function()
                    local cfg = EnsureTypeConfig(effect.auraName, effect.typeKey)
                    cfg.borderMode = nil  -- shared is default
                    S.SwitchTab("effects")
                    RefreshPreviewEffects()
                end)
                customBtn:SetScript("OnClick", function()
                    local cfg = EnsureTypeConfig(effect.auraName, effect.typeKey)
                    cfg.borderMode = "custom"
                    S.SwitchTab("effects")
                    RefreshPreviewEffects()
                end)

                -- Tooltips via HookScript so they compose with the styler's hover wash.
                sharedBtn:HookScript("OnEnter", function()
                    GUI:ShowTooltip(sharedBtn, {
                        title = L["Shared Border"],
                        lines = {
                            L["Uses a single border per frame. Highest priority wins."],
                        },
                    })
                end)
                sharedBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)
                customBtn:HookScript("OnEnter", function()
                    GUI:ShowTooltip(customBtn, {
                        title = L["Custom Border"],
                        lines = {
                            L["Gets its own independent border overlay. Multiple custom borders can be visible at the same time."],
                        },
                    })
                end)
                customBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

                triggersH = triggersH + 36
            end

            -- Priority slider (frame-level effects only — resolves conflicts when
            -- multiple auras set the same frame effect, e.g. two health bar colors)
            local auraProxy = CreateAuraProxy(effect.auraName)
            local priSlider = GUI:CreateSlider(body, L["Priority"], 1, 10, 1, auraProxy, "priority")
            -- Extra gap above (was +4) so the slider isn't squished against the
            -- triggers / Add Trigger row, plus a little breathing room below before
            -- the effect's Appearance group (increment 54 → 68 → 84 with the note).
            -- x=8 matches the "TRIGGERED BY" section above (Options.lua trigContainer)
            -- so the Priority slider + note line up with the card's other elements.
            priSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(triggersH + 14))
            priSlider:SetWidth(bodyWidth - 16)
            -- Direction note in the standard GUI label style (dim, wrapped) so it
            -- matches every other settings note: HIGHER number = higher priority.
            local priNote = GUI:CreateLabel(body, L["Higher priority wins"], bodyWidth - 16)
            priNote:SetPoint("TOPLEFT", priSlider, "BOTTOMLEFT", 0, -2)
            triggersH = triggersH + 84
        end

        -- ── OTHERS ONLY (Other Buffs tab; placed AND frame-level effects) ──
        -- Not offered for sound: the on-apply sound path has no caster filter
        -- (the sound card carries an explanatory banner instead, see
        -- BuildTypeContent). Writes instance.othersOnly / typeCfg.othersOnly
        -- through the pool-pinned proxy; the filter string ("HELPFUL|!PLAYER")
        -- binds at container build, so toggling is STRUCTURAL (B1 folds it
        -- into every struct sig → the factory Rebuilds).
        if IsOtherTab() and effect.typeKey ~= "sound" then
            local ooCb = GUI:CreateCheckbox(body, L["Others Only"], proxy, "othersOnly", function()
                DF:AuraDesigner_RefreshPage()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end)
            ooCb:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(triggersH + 12))
            ooCb:SetWidth(bodyWidth - 16)
            ooCb.tooltip = L["Only show this effect for other players' casts of the buff."]
            triggersH = triggersH + 34
        end

        local _, bodyH = BuildTypeContent(body, effect.typeKey, effect.auraName, bodyWidth, proxy, triggersH, indicatorGroup, effect.indicatorID)

        -- Bottom collapse bar for the indicator card
        local collapseBarH = 14
        local collapseBar = CreateFrame("Button", nil, body)
        collapseBar:SetHeight(collapseBarH)
        collapseBar:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 1, 1)
        collapseBar:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -1, 1)

        local barBg = collapseBar:CreateTexture(nil, "BACKGROUND")
        barBg:SetAllPoints()
        barBg:SetColorTexture(1, 1, 1, 0.03)

        local barIcon = collapseBar:CreateTexture(nil, "OVERLAY")
        barIcon:SetSize(8, 8)
        barIcon:SetPoint("CENTER", 0, 0)
        barIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
        barIcon:SetVertexColor(1, 1, 1, 0.3)

        collapseBar:SetScript("OnEnter", function()
            barBg:SetColorTexture(1, 1, 1, 0.06)
            barIcon:SetVertexColor(1, 1, 1, 0.6)
        end)
        collapseBar:SetScript("OnLeave", function()
            barBg:SetColorTexture(1, 1, 1, 0.03)
            barIcon:SetVertexColor(1, 1, 1, 0.3)
        end)
        collapseBar:SetScript("OnClick", function()
            expandedCards[cardKey] = false
            S.SwitchTab("effects")
        end)

        local contentH = (bodyH or 50) + triggersH + collapseBarH
        body:SetHeight(contentH)
        totalCardH = totalCardH + contentH
    end

    card:SetHeight(totalCardH)
    return yPos - totalCardH - 5
end

-- ── BUILD EFFECTS TAB ──
S.BuildEffectsTab = function()
    if not S.tabContentFrame then return end
    local parent = S.tabContentFrame
    local yPos = -10
    local tc = GetThemeColor()

    -- "+ Add Indicator" button (prominent, theme-colored border)
    local addBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addBtn:SetHeight(32)
    addBtn:SetPoint("TOPLEFT", 8, yPos)
    addBtn:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    -- Shared primary CTA: accent fill + white label via the styler (was a bespoke
    -- fontstring, which is why AD's and TD's hero labels didn't match).
    GUI:StyleButton(addBtn, { height = 32, primary = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 14 }, text = L["Add Indicator"], font = "DFFontHighlight" })

    -- Dropdown menu for add button
    local menuFrame = CreateFrame("Frame", nil, addBtn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetPoint("TOPRIGHT", addBtn, "BOTTOMRIGHT", 0, -2)
    menuFrame:SetFrameStrata("DIALOG")
    menuFrame:SetFrameLevel(100)
    ApplyBackdrop(menuFrame, {r = 0.10, g = 0.10, b = 0.10, a = 0.98}, C_BORDER)
    menuFrame:Hide()
    menuFrame:EnableMouse(true)

    local PLACED_ITEMS = {
        { label = L["Icon"],   type = "icon"   },
        { label = L["Square"], type = "square" },
        { label = L["Bar"],    type = "bar"    },
    }
    local FRAME_ITEMS = {
        { label = L["Border"],            type = "border"     },
        { label = L["Health Bar Color"],  type = "healthbar"  },
        { label = L["Background Color"],  type = "background" },
        { label = L["Name Text Color"],   type = "nametext"   },
        { label = L["Health Text Color"], type = "healthtext" },
        { label = L["Sound Alert"],       type = "sound"      },
    }

    local my = -4
    local MENU_ROW_H = 24

    -- The menu is two identical sections -- a small dim heading, then one row
    -- per entry coloured by its type badge -- and both were written out in
    -- full. `my` is the running cursor, so these close over it.
    local function AddMenuSection(heading, items, scope)
        local hdr = menuFrame:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(hdr, 9, "")
        hdr:SetPoint("TOPLEFT", 10, my)
        hdr:SetText(heading)
        hdr:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        my = my - 14

        for _, item in ipairs(items) do
            local menuBtn = CreateFrame("Button", nil, menuFrame)
            menuBtn:SetHeight(MENU_ROW_H)
            menuBtn:SetPoint("TOPLEFT", 4, my)
            menuBtn:SetPoint("RIGHT", menuFrame, "RIGHT", -4, 0)
            local bc = BADGE_COLORS[item.type]
            local lbl = menuBtn:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(lbl, 10, "")
            lbl:SetPoint("LEFT", 8, 0)
            lbl:SetText(item.label)
            lbl:SetTextColor(bc.r, bc.g, bc.b)
            local hl = menuBtn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.05)
            local capturedType = item.type
            menuBtn:SetScript("OnClick", function()
                menuFrame:Hide()
                OpenIndicatorPicker(capturedType, scope)
            end)
            my = my - MENU_ROW_H
        end
    end

    AddMenuSection(L["PLACED ON FRAME"], PLACED_ITEMS, "placed")

    -- Divider
    my = my - 4
    local mdiv = menuFrame:CreateTexture(nil, "ARTWORK")
    mdiv:SetPoint("TOPLEFT", 8, my)
    mdiv:SetPoint("RIGHT", menuFrame, "RIGHT", -8, 0)
    mdiv:SetHeight(1)
    mdiv:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
    my = my - 6

    AddMenuSection(L["FRAME-LEVEL EFFECTS"], FRAME_ITEMS, "frame")

    menuFrame:SetHeight(-my + 6)

    addBtn:SetScript("OnClick", function()
        if menuFrame:IsShown() then
            menuFrame:Hide()
        else
            menuFrame:Show()
        end
    end)

    yPos = yPos - 44

    -- ── ACTIVE INDICATORS heading ──
    local activeHeader = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(activeHeader, 9, "")
    activeHeader:SetPoint("TOPLEFT", 8, yPos)  -- align with chips/cards/add button
    activeHeader:SetText(L["ACTIVE INDICATORS"])
    activeHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 16

    -- ── FILTER CHIPS (wrapping layout) ──
    local chipsFrame = CreateFrame("Frame", nil, parent)
    chipsFrame:SetPoint("TOPLEFT", 8, yPos)
    chipsFrame:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

    local FILTER_CHIPS = {
        { key = "all",         label = L["All"]    },
        { key = "icon",        label = L["Icon"]   },
        { key = "square",      label = L["Square"] },
        { key = "bar",         label = L["Bar"]    },
        { key = "border",      label = L["Border"] },
        { key = "healthbar",   label = L["Health"] },
        { key = "nametext",    label = L["Name"]   },
        { key = "healthtext",  label = L["HP"]     },
    }

    local CHIP_H = 22
    local CHIP_GAP = 4
    local CHIP_ROW_GAP = 4
    local chipBtns = {}

    for _, chip in ipairs(FILTER_CHIPS) do
        local chipBtn = CreateFrame("Button", nil, chipsFrame, "BackdropTemplate")
        chipBtn:SetHeight(CHIP_H)

        local chipTxt = chipBtn:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(chipTxt, 10, "OUTLINE")
        chipTxt:SetPoint("CENTER", 0, 0)
        chipTxt:SetText(chip.label)
        chipTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local tw = chipTxt:GetStringWidth()
        chipBtn:SetWidth(max(tw + 16, 32))

        -- Shared styling: standard hover + an active (selected) state marked by a
        -- prominent accent border. The row rebuilds on click, so set active here.
        GUI:StyleButton(chipBtn)
        chipBtn:SetActive(S.activeFilter == chip.key)

        local capturedKey = chip.key
        chipBtn:SetScript("OnClick", function()
            S.activeFilter = capturedKey
            S.SwitchTab("effects")
        end)

        tinsert(chipBtns, chipBtn)
    end

    -- Flow-layout: position chips with wrapping on parent resize
    local function LayoutChips()
        local maxW = chipsFrame:GetWidth()
        if maxW < 20 then maxW = 260 end
        local cx, cy = 0, 0
        for _, btn in ipairs(chipBtns) do
            local bw = btn:GetWidth()
            if cx > 0 and (cx + bw) > maxW then
                cx = 0
                cy = cy - (CHIP_H + CHIP_ROW_GAP)
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", chipsFrame, "TOPLEFT", cx, cy)
            cx = cx + bw + CHIP_GAP
        end
        chipsFrame:SetHeight(max(-cy + CHIP_H, CHIP_H))
    end
    LayoutChips()
    chipsFrame:SetScript("OnSizeChanged", LayoutChips)

    yPos = yPos - (chipsFrame:GetHeight() + 10)

    -- ── OTHER BUFFS HINT ──
    if IsOtherTab() then
        local obHint = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        obHint:SetPoint("TOPLEFT", 8, yPos)
        obHint:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        obHint:SetJustifyH("LEFT")
        obHint:SetWordWrap(true)
        obHint:SetText(L["These indicators trigger no matter who casts the buff."])
        obHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
        yPos = yPos - (max(obHint:GetStringHeight(), 12) + 10)
    end

    -- ── EFFECTS LIST ──
    local effects = CollectAllEffects()

    -- Apply filter
    local filtered = {}
    for _, effect in ipairs(effects) do
        if S.activeFilter == "all" or effect.typeKey == S.activeFilter then
            tinsert(filtered, effect)
        end
    end

    if #filtered == 0 then
        local empty = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        empty:SetPoint("TOP", parent, "TOP", 0, yPos - 30)
        empty:SetWidth(220)
        local spec = ResolveSpec()
        local specAuras = spec and Adapter:GetTrackableAuras(spec)
        -- The Other Buffs pool is spec-independent — never show the
        -- unsupported-spec message there.
        if not IsOtherTab() and (not spec or not specAuras or #specAuras == 0) then
            empty:SetText(L["No trackable spells found for this spec.\n\nYou can select a different spec using the dropdown above."])
        elseif S.activeFilter == "all" then
            empty:SetText(L["No effects configured yet.\nClick '+ Add Indicator' to get started."])
        else
            empty:SetText(format(L["No %s effects configured."], (S.PLACED_TYPE_LABELS[S.activeFilter] or S.FRAME_LEVEL_LABELS[S.activeFilter] or S.activeFilter)))
        end
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        for _, effect in ipairs(filtered) do
            yPos = S.CreateEffectCard(parent, yPos, effect)
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ── BUILD GLOBAL TAB ──
-- Wraps the existing BuildGlobalView into the tab content frame
S.BuildGlobalTab = function()
    if not S.tabContentFrame then return end
    BuildGlobalView(S.tabContentFrame)
end

-- ── BUILD LAYOUT GROUPS TAB ──
-- ============================================================
-- GROUP APPEARANCE SECTION (filter-group + debuff-group cards)
-- Collapsible "Appearance" SettingsGroup (the effect-card section idiom)
-- holding the per-group icon styling the container genuinely supports:
-- cooldown swipe, border (full CreateBorderControls set incl. the DF-owned
-- animations), duration text (show / font / scale / outline / anchor /
-- offsets / colour-by-time / colour / hide-above) and stack count (show +
-- text styling). Controls bind to group.style via a defaults proxy
-- (CreateInstanceProxy's idiom): nil keys read the pre-style defaults, so
-- an untouched section changes nothing — the factory renders a style-less
-- (or all-default) group byte-identically to before. Omitted vs the placed
-- effect card, by capability: Min Stacks (no formatter on the native stack
-- path — secret trap), Hide Icon / size / scale / alpha / frame level
-- (group-level layout already owns size; the rest are per-indicator
-- concepts), Expiring / Show When Missing (remaining-time / presence reads).
-- Structural fields (show toggles, colour-by-time, hide-above, border
-- on/off) move the group struct sig -> the factory Rebuilds; everything
-- else hot-applies via the cosmetic sig. Collapse state persists PER CARD
-- under "adGroupStyle:<cardKey>" — cardKey is the caller's expand-key form
-- (raw id / "othergroup:<id>" / "dgroup:<id>"), so the three stores' keys
-- stay disjoint from each other and from the effect cards' header keys.
local function AddGroupAppearanceSection(body, group, bodyWidth, by, cardKey)
    local s = group.style
    if type(s) ~= "table" then s = {}; group.style = s end

    -- Defaults = today's uniform group rendering (Factory buildFilterGroupStyle's
    -- pre-style values) + the icon indicator's Border* seeds so CreateBorderControls
    -- reads sensible values on first open (ShowBorder overridden OFF — a group has
    -- no ring until the user enables one).
    local defaults = {
        hideSwipe = false, showDuration = true, showStacks = true,
        durationFormat = "NUMBER",
        durationFont = "DF Roboto SemiBold", durationScale = 1.0, durationOutline = "SHADOW;OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = false, durationColor = { r = 1, g = 1, b = 1, a = 1 },
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        durationHideOnPermanent = true,   -- Wave 4: absent key = ON (style-less identity)
        stackFont = "DF Roboto SemiBold", stackScale = 1.0, stackOutline = "SHADOW;OUTLINE",
        stackAnchor = "BOTTOMRIGHT", stackX = 2, stackY = -1,
        stackColor = { r = 1, g = 1, b = 1, a = 1 },
        ShowBorder = false,
        -- Duration bar strip (Wave 3) — mirrors the row pages' defaults
        -- (Config.lua buffDurationBar*). OFF until the user enables it.
        durationBarEnabled = false, durationBarPosition = "BOTTOM",
        durationBarHeight = 4, durationBarGap = 1, durationBarColorMode = "STATIC",
        durationBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
        durationBarColor = { r = 0.2, g = 0.9, b = 0.3, a = 1 },
        durationBarBGColor = { r = 0, g = 0, b = 0, a = 0.8 },
        durationBarReverseFill = false,
    }
    for k, v in pairs(TYPE_DEFAULTS.icon) do
        if k:find("^Border") and defaults[k] == nil then defaults[k] = v end
    end

    -- Defaults proxy (CreateInstanceProxy's idiom, group.style-backed): reads fall
    -- through to the defaults (table fallbacks copy-on-read so colour sub-key edits
    -- persist); writes land in group.style and refresh the live frames. The factory
    -- reads the RAW style table with the same defaults, so UI and render agree.
    local proxy = setmetatable({ _skipOverrideIndicators = true, __dfDefaults = defaults }, {
        __index = function(_, k)
            local val = s[k]
            if val ~= nil then return val end
            local fallback = defaults[k]
            if type(fallback) == "table" then
                local copy = {}
                for fk, fv in pairs(fallback) do copy[fk] = fv end
                s[k] = copy
                return copy
            end
            return fallback
        end,
        __newindex = function(_, k, v)
            s[k] = v
            RefreshPlacedIndicators()
            RefreshLiveFramesThrottled()
        end,
    })

    -- Cosmetic edits hot-apply (coSig -> ApplyStyle); structural toggles move the
    -- struct sig -> Rebuild. Both ride the same throttled factory re-sync. The
    -- canvas placeholder's sample icons render the group style too, so every
    -- appearance edit re-draws them (RefreshPlacedIndicators — the same direct
    -- call the card's layout sliders run per edit/drag).
    local function refresh()
        RefreshPlacedIndicators()
        RefreshLiveFramesThrottled()
    end
    -- Visibility changes inside the section (border style dropdown swapping its
    -- widget set) re-measure heights, so rebuild the tab — the same full-rebuild
    -- the effect cards' dropdown callbacks run (AuraDesigner_RefreshPage).
    local function rebuildTab() S.SwitchTab("layout") end

    -- One collapsible box PER CATEGORY — the expanded effect card's section
    -- structure (Appearance / Border / Duration Text / Stack Count, same names
    -- and order as the icon card's AddGroup boxes; group-inapplicable sections
    -- — Position, Show When Missing, Expiring — have no group-level analogue).
    -- Collapse persists per card per section ("adGroupStyle:<cardKey>:<section>"),
    -- so each section toggles independently; the toggle rides the widget's
    -- built-in AuraDesigner_RefreshPage rebuild like the effect cards'.
    local function AddSection(header, sectionKey, buildFn)
        local g = GUI:CreateSettingsGroup(body, bodyWidth - 10, {
            collapsible = true,
            collapseKey = "adGroupStyle:" .. tostring(cardKey) .. ":" .. sectionKey,
        })
        g.padding = 10   -- match the main Options groups' inner padding (airier scale)
        g:AddWidget(GUI:CreateHeader(body, header), GUI.RowHeight.sectionHeader)
        buildFn(g)
        local h = g:LayoutChildren()   -- includes the group's own bottom margin
        g:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
        by = by - h
    end

    -- ── APPEARANCE ── (the effect card's Appearance box; of its controls only
    -- the swipe applies at group level — size/scale live in the card's layout
    -- sliders, alpha/level/strata/text-only are per-indicator concepts)
    AddSection(L["Appearance"], "appearance", function(g)
        g:AddWidget(GUI:CreateCheckbox(body, L["Hide Cooldown Swipe"], proxy, "hideSwipe", refresh), 28)
    end)

    -- ── BORDER ── (the placed icon's control set; gradient degrades to solid on
    -- container slots — same known casualty as placed indicators; LCG glow types
    -- are excluded from the animation dropdown, mirror the placed border)
    AddSection(L["Border"], "border", function(g)
        GUI:CreateBorderControls(g, proxy, "", {
            parent  = body,
            include = {
                inset = true, offset = true, blendMode = true,
                gradient = true, shadow = true, alpha = true,
            },
            fullUpdate    = refresh,
            lightUpdate   = refresh,
            lightColors   = refresh,
            refreshStates = rebuildTab,
            sizeMin = 1, sizeMax = 5, sizeStep = 1,
        })
    end)

    -- ── DURATION TEXT ── (shared text controls; keys mirror the placed cards')
    AddSection(L["Duration Text"], "duration", function(g)
        g:AddWidget(GUI:CreateCheckbox(body, L["Show Duration"], proxy, "showDuration", refresh), 28)
        -- Icon-sized formats only — a group renders icon rows (see the placed icon
        -- card's Duration Format note). Structural: the proxy write's refresh moves
        -- durationFmtKey -> the factory Rebuilds. Forward-declared
        -- UpdateHideAboveState (assigned below): re-greys Hide Above, which can't
        -- compose with the percent-family formats.
        local UpdateHideAboveState
        g:AddWidget(GUI:CreateDropdown(body, L["Duration Format"], {
            NUMBER = L["Number"], SHORT = L["Seconds"], PERCENT = L["Percent"],
            _order = { "NUMBER", "SHORT", "PERCENT" },
        }, proxy, "durationFormat", function() if UpdateHideAboveState then UpdateHideAboveState() end end), 54)
        GUI:CreateTextControls(g, proxy, "duration", {
            parent = body,
            include = { color = true },
            colorLabel = L["Duration Text Color"],
            colorDisableOn = function() return proxy.durationColorByTime and true or false end,
            onChange = refresh, onDrag = refresh,
        })
        g:AddWidget(GUI:CreateCheckbox(body, L["Color by Time Remaining"], proxy, "durationColorByTime", refresh), 28)
        AddDurationColorsLink(g, body)
        local hideAboveSlider, hideAboveCheck
        UpdateHideAboveState = function()
            if not hideAboveSlider then return end
            local pctFmt = DF.IsPercentDurationFormat and DF:IsPercentDurationFormat(proxy.durationFormat)
            if hideAboveCheck and hideAboveCheck.SetEnabled then hideAboveCheck:SetEnabled(not pctFmt) end
            if not pctFmt and proxy.durationHideAboveEnabled then
                hideAboveSlider:SetAlpha(1)
                hideAboveSlider:EnableMouse(true)
            else
                hideAboveSlider:SetAlpha(0.4)
                hideAboveSlider:EnableMouse(false)
            end
        end
        hideAboveCheck = GUI:CreateCheckbox(body, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", function()
            UpdateHideAboveState()
            refresh()
        end)
        g:AddWidget(hideAboveCheck, 28)
        hideAboveSlider = GUI:CreateSlider(body, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold", refresh, refresh, true)
        g:AddWidget(hideAboveSlider, 54)
        g:AddWidget(GUI:CreateCheckbox(body, L["Hide Duration on Permanent Auras"], proxy, "durationHideOnPermanent", refresh), 28)
        UpdateHideAboveState()
    end)

    -- ── STACK COUNT ── (no Min Stacks — not expressible on the native no-formatter
    -- stack path, see Features/Auras.lua's stacks-formatter warning)
    AddSection(L["Stack Count"], "stacks", function(g)
        g:AddWidget(GUI:CreateCheckbox(body, L["Show Stacks"], proxy, "showStacks", refresh), 28)
        GUI:CreateTextControls(g, proxy, "stack", {
            parent = body,
            include = { color = true },
            colorLabel = L["Stack Text Color"],
            onChange = refresh, onDrag = refresh,
        })
    end)

    -- ── DURATION BAR ── (Wave 3: strip below/above each icon, drained by the
    -- native SetDurationBar fill — render-side, works on secret auras. The keys
    -- mirror the row pages' buffDurationBar* block; enable/position/height/gap
    -- are structural (group struct sig -> Rebuild), texture/colours hot-apply.)
    AddSection(L["Duration Bar"], "durationbar", function(g)
        -- Greys IMPERATIVELY, not via widget.disableOn: this is an AD editor card, which
        -- has no disableOn/RefreshStates loop (that seam only runs on the SettingsGroup
        -- row pages). The enable gate AND the curve-mode dimming of Texture/Bar Color are
        -- driven by hand from the Enable + Color Mode callbacks. curveGated flags the two
        -- controls a curve mode overrides.
        local dbWidgets, curveGated = {}, {}
        local function UpdateBarGrey()
            local on = proxy.durationBarEnabled and true or false
            local curve = DF:IsDurationBarCurveMode(proxy.durationBarColorMode)
            for i = 1, #dbWidgets do
                local w = dbWidgets[i]
                local enable = on and not (curveGated[w] and curve)
                if w.SetEnabled then w:SetEnabled(enable)
                else
                    w:SetAlpha(enable and 1 or 0.4)
                    if w.EnableMouse then w:EnableMouse(enable) end
                end
            end
        end
        g:AddWidget(GUI:CreateCheckbox(body, L["Enable Duration Bar"], proxy, "durationBarEnabled", function()
            UpdateBarGrey()
            refresh()
        end), 28)
        local function barChild(widget, h)
            g:AddWidget(widget, h)
            dbWidgets[#dbWidgets + 1] = widget
            return widget
        end
        barChild(GUI:CreateDropdown(body, L["Position"], { BOTTOM = L["Bottom"], TOP = L["Top"] }, proxy, "durationBarPosition", refresh), 54)
        barChild(GUI:CreateSlider(body, L["Height"], 1, 12, 1, proxy, "durationBarHeight", refresh, refresh, true), 54)
        barChild(GUI:CreateSlider(body, L["Gap"], 0, 10, 1, proxy, "durationBarGap", refresh, refresh, true), 54)
        barChild(GUI:CreateDropdown(body, L["Color Mode"],
            DF:GetDurationBarColorModes(),
            proxy, "durationBarColorMode", function() UpdateBarGrey(); refresh() end), 54)
        -- A curve mode brings its own ramp texture and forces a white tint, so these two
        -- do nothing while it is selected - dim them (curveGated) rather than leave dead
        -- controls live.
        local adBarTex = barChild(GUI:CreateTextureDropdown(body, L["Bar Texture"], proxy, "durationBarTexture", refresh), 54)
        local adBarCol = barChild(GUI:CreateColorPicker(body, L["Bar Color"], proxy, "durationBarColor", true, refresh, refresh, true), 28)
        curveGated[adBarTex] = true; curveGated[adBarCol] = true
        barChild(GUI:CreateColorPicker(body, L["Background Color"], proxy, "durationBarBGColor", true, refresh, refresh, true), 28)
        barChild(GUI:CreateCheckbox(body, L["Reverse Fill"], proxy, "durationBarReverseFill", refresh), 28)
        UpdateBarGrey()
    end)

    return by
end

-- ☠ Published HERE, in the part that DEFINES it -- see the note in Options.lua.
P.AddGroupAppearanceSection = AddGroupAppearanceSection