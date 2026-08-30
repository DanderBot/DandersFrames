-- Part 5 of the Aura Designer editor: the POPOUT LAYOUT's page.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`).
local DF = DandersFrames
local L = DF.L
local GUI = DF.GUI
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv

local ipairs, pairs, type = ipairs, pairs, type
local format = string.format
local max = math.max
local wipe = wipe

local C_TEXT_DIM = GUI.Colors.textDim

-- Aliases of things the earlier parts built. Load-time constants, exactly as the
-- other parts take them.
local OPTS                     = P.OPTS
local ResolveSpec              = P.ResolveSpec
local IsOtherTab               = P.IsOtherTab
local IsDebuffTab              = P.IsDebuffTab
local CurrentAuraPool          = P.CurrentAuraPool
local CollectAllEffects        = P.CollectAllEffects
local GetAuraIcon              = P.GetAuraIcon
local GetAuraWarningKey        = P.GetAuraWarningKey
local AttachWarningBadge       = P.AttachWarningBadge
local GetIndicatorLayoutGroup  = P.GetIndicatorLayoutGroup
local GetFrameEffectTriggers   = P.GetFrameEffectTriggers
local RemoveIndicatorInstance  = P.RemoveIndicatorInstance
local CreateInstanceProxy      = P.CreateInstanceProxy
local CreateProxy              = P.CreateProxy
local CreateSpecDropdown       = P.CreateSpecDropdown
local CreateEnableBanner       = P.CreateEnableBanner
local CreateFramePreview       = P.CreateFramePreview
local BuildTypeContent         = P.BuildTypeContent
local RefreshPlacedIndicators  = P.RefreshPlacedIndicators
local RefreshPreviewEffects    = P.RefreshPreviewEffects
local RefreshLiveFramesThrottled = P.RefreshLiveFramesThrottled
local SetMainTab               = P.SetMainTab
local UpdateSpecDropdownState  = P.UpdateSpecDropdownState
local PoolKeyPrefix            = P.PoolKeyPrefix
local expandedCards            = P.expandedCards
local mainTabButtons           = P.mainTabButtons
-- ...and the Layout Groups / Global halves, which phase 3 brought over.
local CurrentLayoutGroups        = P.CurrentLayoutGroups
local DebuffGroupsRead           = P.DebuffGroupsRead
local GroupExpandKey             = P.GroupExpandKey
local expandedGroups             = P.expandedGroups
local DeleteLayoutGroup          = P.DeleteLayoutGroup
local DeleteDebuffGroup          = P.DeleteDebuffGroup
local GroupRecordView            = P.GroupRecordView
local DebuffGroupRecordView      = P.DebuffGroupRecordView
local DebuffSelectionView        = P.DebuffSelectionView
local AddGroupAppearanceSection  = P.AddGroupAppearanceSection
local BuildGlobalView            = P.BuildGlobalView
-- ☠ NOT ALIASED, READ AT CALL TIME. Editor.lua declares these and it loads AFTER
-- this file (see the companion's TOC), so a load-time local would freeze nil --
-- silently, because a nil upvalue only errors when the tab is opened. Everything
-- above comes from Options.lua / Groups.lua / Cards.lua, all of which load first.
--   P.CollectLayoutGroupSections   P.CollectDebuffGroupSections
--   P.EnsureDebuffSelection

-- The SPLIT PANEL's pool tab strip. The band layout has its own strip now (see
-- S.BuildPoolTabs) and it is the same height, so the two layouts spend the same
-- 30px on the same three words.
local BUFFTAB_H = 30
-- ...and the band layout's, above the canvas. Same number, named separately
-- because the two are different objects with different art and only one of them
-- may ever be mounted at a time.
local POOLTABS_H = 30
-- How much shorter an UNSELECTED folder tab is, which is also how far its top
-- edge sits below the selected one's. See GUI:StyleFolderTab.
local POOLTAB_SETBACK = 6
local POOLTAB_GAP = 4

-- ── THE SCOPE ROW ──
-- One band for the "which set am I editing" picker that has no picture of its
-- own. SCOPEROW_H is a 22px opener plus 2px of air above and below it.
local SCOPEROW_H = 26
-- Between a caption and the opener it names.
local LABEL_GAP  = 8
-- The canvas band's FLOOR. Its actual height is P.CanvasWantedHeight, which
-- grows with the preview scale; this is what that returns at 1.0.
local CANVAS_H  = 132

-- The width a pane's contents are built at, asked for rather than guessed -- the
-- same constant CreatePopoutPageTools mounts its groups at, so a control built
-- here is exactly the width it would be anywhere else in a panel. Read at CALL
-- time: the kit publishes it at load, and a file-scope copy would freeze whatever
-- was there when this file parsed.
local function PopoutWidth() return GUI.PopoutContentWidth or 260 end

-- ============================================================
-- THE POOL STRIP -- THE SPLIT PANEL'S ARM ONLY
-- ------------------------------------------------------------
-- My Buffs / Debuffs / Any Buff as three tab buttons, in a slice of S.mainFrame
-- (Editor.lua). The band layout no longer mounts this: two stacked tab strips
-- read as tabs inside tabs, so its pool is a picker on the scope row below. The
-- three pools differ on two axes the labels can't carry, so each tab explains
-- itself on hover -- and the picker carries all three explanations at once.
-- ============================================================
-- ⚠ A FUNCTION, NOT A FILE-SCOPE TABLE. Every label and every tooltip line is an
-- L[...] lookup, and a table built at load freezes whatever locale was live then
-- -- the trap DF:RegisterLocaleRefresh exists for. Two callers now read it: the
-- split panel's strip below and the scope row's picker.
local function PoolDefs()
    return {
        { key = "my",      label = L["My Buffs"], tooltip = {
            L["Buffs from your own class, and only when you cast them."],
            L["Set up separately for each specialization."],
        } },
        { key = "debuffs", label = L["Debuffs"], tooltip = {
            L["Groups of debuffs picked by category — boss, crowd control, dispellable and so on — rather than one spell at a time."],
            L["Shared across all your specializations."],
        } },
        { key = "other",   label = L["Any Buff"], tooltip = {
            L["Any buff in the spell database, from any caster — including your own."],
            L["Turn on Others Only for an effect to ignore your own casts."],
            L["Shared across all your specializations."],
        } },
    }
end

S.BuildPoolStrip = function(buffTabBar)
    local MAIN_TAB_DEFS = PoolDefs()
    wipe(mainTabButtons)
    local prevMainBtn
    for _, def in ipairs(MAIN_TAB_DEFS) do
        local btn = CreateFrame("Button", nil, buffTabBar, "BackdropTemplate")
        GUI:StyleButton(btn, { height = BUFFTAB_H - 4, text = def.label, font = "DFFontHighlight" })
        btn.Text:ClearAllPoints()
        btn.Text:SetPoint("CENTER", 0, 0)
        -- Width comes from the strip, not from the label -- see the OnSizeChanged
        -- below. A build-time width of max(text+28, 96) needed 296px for three
        -- tabs, which the 850px island always had and a 640px window does not.
        if prevMainBtn then
            btn:SetPoint("LEFT", prevMainBtn, "RIGHT", 4, 0)
        else
            btn:SetPoint("LEFT", buffTabBar, "LEFT", 0, 0)
        end
        local capturedKey = def.key
        btn:SetScript("OnClick", function() SetMainTab(capturedKey) end)
        -- HookScript, not SetScript: StyleButton owns OnEnter/OnLeave for the
        -- hover wash, and replacing them would leave the tab stuck lit.
        local tipTitle, tipLines = def.label, def.tooltip
        btn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, { title = tipTitle, lines = tipLines })
        end)
        btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        btn:SetActive(S.activeBuffTab == def.key)
        mainTabButtons[def.key] = btn
        prevMainBtn = btn
    end

    -- ☠ EQUAL WIDTH, DIVIDED FROM THE STRIP, exactly as the sub-tab strip below
    -- does it (GUI/DesignerShell.lua). The three tabs are one control -- a
    -- three-way switch -- so they should read as three equal halves of the band
    -- rather than three labels of whatever width their words happen to be, and
    -- at the 640px default their words do not fit any other way.
    local nTabs = #MAIN_TAB_DEFS
    buffTabBar:SetScript("OnSizeChanged", function(self, w)
        if not w or w < 10 then return end
        local tabW = (w - (nTabs - 1) * 4) / nTabs
        for i = 1, nTabs do
            local b = mainTabButtons[MAIN_TAB_DEFS[i].key]
            if b then b:SetWidth(tabW) end
        end
    end)
    local w0 = buffTabBar:GetWidth()
    if w0 and w0 > 10 then
        local tabW = (w0 - (nTabs - 1) * 4) / nTabs
        for i = 1, nTabs do
            local b = mainTabButtons[MAIN_TAB_DEFS[i].key]
            if b then b:SetWidth(tabW) end
        end
    end
end

-- ============================================================
-- THE POOL TABS -- WHAT THE PREVIEW IS SHOWING
-- ------------------------------------------------------------
-- ☠ TWO STACKED TAB STRIPS READ AS ONE BLOCK. The pool strip sat directly above
-- Effects / Layout Groups / Global and the pair looked like tabs inside tabs --
-- "so confusion to know that they are tabs within tabs". Hiding the pool in a
-- dropdown solved that and cost the three per-tab tooltips, which were the only
-- place the two axes the pools differ on were written down.
--
-- ☠ SO THE TABS COME BACK, AND MOVE INSTEAD. They go ABOVE the frame preview,
-- which then physically separates them from the sub-tabs: the nesting is solved
-- by distance rather than by hiding, and the tooltips return. They are drawn as
-- FOLDER TABS joined to the preview panel -- the selected one continuous with the
-- panel below it, the rest set back behind it -- so they read as belonging to
-- that preview rather than as a second row of the strip lower down. See
-- GUI:StyleFolderTab, which owns that language.
--
-- ⚠ AND THEY STILL CHOOSE MORE THAN THE PICTURE. The pool decides which effects
-- the list shows and which spec applies, not only what the mock is drawn with; the
-- tabs sit on the canvas because that is where they stop competing with the
-- sub-tabs, not because the canvas is all they touch.
-- ============================================================
S.BuildPoolTabs = function(host)
    local defs = PoolDefs()
    wipe(mainTabButtons)

    for _, def in ipairs(defs) do
        local btn = CreateFrame("Button", nil, host, "BackdropTemplate")
        local capturedKey = def.key
        GUI:StyleFolderTab(btn, {
            text     = def.label,
            font     = "DFFontHighlight",
            setBack  = POOLTAB_SETBACK,
            -- The three explanations, one per tab, exactly as they were before the
            -- dropdown pass stacked all three on one opener.
            tooltip  = { title = def.label, lines = def.tooltip },
            onClick  = function() SetMainTab(capturedKey) end,
        })
        btn:SetActive(S.activeBuffTab == def.key)
        mainTabButtons[def.key] = btn
    end

    -- ☠ EQUAL WIDTH, DIVIDED FROM THE STRIP, exactly as the sub-tab strip below
    -- does it (GUI/DesignerShell.lua) and as the split panel's own strip does. The
    -- three tabs are one control -- a three-way switch -- so they read as three
    -- equal parts of the band rather than three labels of whatever width their
    -- words happen to be, and at the 640px default their words do not fit any
    -- other way. The x is handed to the tab rather than anchored here because a
    -- folder tab re-issues BOTH its own vertical points on every SetActive.
    local n = #defs
    local function SizeTabs(w)
        w = w or host:GetWidth() or 0
        if not w or w < 10 then return end
        local tabW = (w - (n - 1) * POOLTAB_GAP) / n
        for i = 1, n do
            local b = mainTabButtons[defs[i].key]
            if b then
                b:SetWidth(tabW)
                b:SetFolderX((i - 1) * (tabW + POOLTAB_GAP))
            end
        end
    end
    host:SetScript("OnSizeChanged", function(_, w) SizeTabs(w) end)
    SizeTabs()
end

-- ============================================================
-- THE SCOPE ROW -- WHICH SET AM I EDITING
-- ------------------------------------------------------------
-- One band, one picker: Spec. The pool used to share it and has gone up to the
-- canvas tabs; what is left is the one "which set am I editing" question with no
-- picture of its own.
--
-- ☠ SPEC DID NOT JOIN THE TEMPLATE ROW, AND THE MEASUREMENT IS WHY. The plan
-- was to fold this band away entirely by putting Spec beside Template on the
-- banner's second row. Two labelled pickers is a smaller sum than the three that
-- were refused before, but not small enough: at the window's 520px MINIMUM the
-- band is ~301px and the preset bar spans it less its 10px insets, so 281px has
-- to carry "Template:" (~45) + "Spec:" (~25) + two caption gaps (14) + the
-- overflow glyph (22) + the gap between the halves (10) -- leaving ~165px for TWO
-- openers, about 82px each. Section 17 of the rework spec called 113px "usable,
-- not comfortable"; 82px shows roughly ten characters of "Auto (Restoration
-- Shaman)", which is not enough to tell one spec's auto-label from another's. It
-- is also WORSE than today, where Spec gets ~118px on a band of its own. So the
-- band stays, and Spec takes the whole of it -- which is the one thing this pass
-- does improve, since the pool leaving gives it ~263px instead of ~156px.
--
-- ⚠ AND SPEC GREYS WHEN THE POOL IS NOT MY BUFFS. Debuffs and Any Buff are
-- shared across specs. The pool tabs are two bands up rather than adjacent now,
-- which is the cost of the move; the greying still fires on the same call.
-- ============================================================
S.BuildScopeRow = function(host)
    S.BuildSpecPicker(host)
end

-- ⚠ SPEC STAYS VISIBLE and greys on the pools that have no spec (Debuffs and Any
-- Buff are shared across specs), rather than hiding -- that is the addon's
-- grey-when-disabled convention, and hiding it would change the row's shape on
-- every pool switch. UpdateSpecDropdownState owns the greying, and a pool change
-- reaches it twice: SetMainTab calls it directly, then the page rebuild it
-- triggers runs this builder again on the new dropdown.
S.BuildSpecPicker = function(host)
    local specLabel = host:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    specLabel:SetText(L["Spec:"])
    specLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    specLabel:SetPoint("LEFT", host, "LEFT", 2, 0)

    S.specDropdown, S.specDropdownUpdate = CreateSpecDropdown(host)
    S.specDropdown:SetHeight(22)
    -- Anchored to BOTH edges rather than given a width: the band is whatever the
    -- window is, and a 165px dropdown floating in the middle of it reads as a
    -- stray control instead of a row. Spec names are the long ones
    -- ("Auto (Restoration Shaman)"), so every pixel of the band goes to it.
    S.specDropdown:SetPoint("LEFT", specLabel, "RIGHT", LABEL_GAP, 0)
    S.specDropdown:SetPoint("RIGHT", host, "RIGHT", -2, 0)
    UpdateSpecDropdownState()
end

-- ============================================================
-- ONE EFFECT'S ROWS
-- ------------------------------------------------------------
-- ☠ THE EFFECT ITSELF IS EXPAND-ONLY. It is a way in to ten groups, not a group,
-- so a panel on it would be a panel that had to contain ten more -- and the
-- popout system is deliberately ONE level deep. The effect is a collapsible
-- SECTION whose header carries the identity (the spell's own icon, the type
-- badge's label, the anchor or trigger count, the eye and the delete), and the
-- rows in the band under it each own one panel.
--
-- ☠ AND A COLLAPSED EFFECT BUILDS NO ROWS AT ALL. A popout row's pane is built
-- EAGERLY, at page-build time (CreatePopoutPageTools' PopoutContent says why:
-- the settings-search registry is built by re-running every page's builder, so a
-- widget that did not exist until the panel opened would be a widget search can
-- never find). So "a row is cheap because its pane is lazy" is FALSE here -- what
-- is cheap is not adding the rows. That is the same bargain the card layout
-- struck with expandedCards, and it is why this keeps that table rather than
-- letting the section's own fold persist into SavedVariables.
-- ============================================================

-- The row order per effect type, as a card reads downward: does it show -> where
-- -> how big -> what it looks like -> what is drawn on it -> what changes it over
-- time. It is NOT declared here: it is whatever BuildTypeContent's collect pass
-- returns, which is the SAME branch order the card builds, so the two layouts
-- cannot disagree about which sections an effect has.

-- What a write behind any of this effect's rows costs. Handed to every row's
-- footer, so Reset Group and Hold: Defaults drive exactly what the controls'
-- own callbacks drive.
local function ApplyEffectGroup()
    RefreshLiveFramesThrottled()
    RefreshPlacedIndicators()
    RefreshPreviewEffects()
    local E = DF.AuraDesigner and DF.AuraDesigner.Engine
    if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
end

-- An effect's name, in the long form a row title and a search breadcrumb want:
-- "Icon — Power Word: Shield". The short form is the section header's.
local function EffectTitle(effect)
    local typeLabel = (effect.source == "placed")
        and (S.PLACED_TYPE_LABELS[effect.typeKey] or effect.typeKey)
        or  (S.FRAME_LEVEL_LABELS[effect.typeKey] or effect.typeKey)
    return format("%s \226\128\148 %s", typeLabel, effect.displayName or "")
end

-- The one-line status the section header carries beside its title: which layout
-- group manages it, or where it sits, or how many triggers it answers to.
local function EffectTag(effect, indicatorGroup)
    local parts = {}
    if effect.source == "placed" then
        if indicatorGroup then
            parts[#parts + 1] = indicatorGroup.name
        elseif effect.anchor then
            parts[#parts + 1] = OPTS.ANCHOR_OPTIONS[effect.anchor] or effect.anchor
        end
    else
        local triggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
        if #triggers > 1 then
            parts[#parts + 1] = format(L["+%d triggers"], #triggers - 1)
        end
    end
    if IsOtherTab() and effect.config and effect.config.othersOnly then
        parts[#parts + 1] = L["Others Only"]
    end
    return table.concat(parts, " \194\183 ")
end

-- The stable identity of one effect's fold state. Verbatim from the card layout,
-- so switching layouts does not re-collapse everything the user had open.
local function EffectCardKey(effect)
    local prefix = PoolKeyPrefix()
    if effect.source == "placed" then
        return "placed:" .. prefix .. effect.auraName .. "#" .. tostring(effect.indicatorID)
    end
    return "frame:" .. effect.typeKey .. ":" .. prefix .. effect.auraName
end

-- ============================================================
-- THE PAGE
-- ============================================================

-- ctx carries what BuildPage handed the builder plus the shared popout machinery:
-- { page, db, Add, AddSpace, tools }.
local function MountEffect(ctx, effect, shell)
    local page, tools, Add = ctx.page, ctx.tools, ctx.Add
    local bandW  = tools.BandWidth()
    local cardKey = EffectCardKey(effect)
    local title  = EffectTitle(effect)
    local isPlaced = effect.source == "placed"
    local indicatorGroup = isPlaced
        and GetIndicatorLayoutGroup(effect.auraName, effect.indicatorID) or nil

    local section = GUI:CreateCollapsibleSection(page.child, title, false, bandW)
    -- ⚠ THE FOLD STATE IS expandedCards, NOT collapsedGroups. The section factory
    -- reads and writes the shared per-title store, and these titles carry SPELL
    -- NAMES -- one entry per placed effect per pool, accumulating in the profile
    -- forever. The rework is a pure re-presentation, so it adds no keys: the
    -- state stays in the same in-memory table the card layout used, and Toggle is
    -- replaced rather than hooked so the factory's own write never runs.
    section.expanded = expandedCards[cardKey] and true or false
    section.arrow:SetTexture(section.expanded
        and "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more"
        or  "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    section.Toggle = function(self)
        expandedCards[cardKey] = not self.expanded or nil
        -- A rebuild, not a state pass: the rows under a collapsed effect are not
        -- BUILT, so there is nothing for RefreshStates to reveal.
        if page.Refresh then page:Refresh() end
    end

    -- The spell's own artwork on the header. A filter-owned record shows our
    -- filter glyph instead, which the swatch draws un-cropped -- the 0.08/0.92
    -- crop exists to trim the border baked into Blizzard's spell art and merely
    -- zooms into a clean glyph.
    local iconTex = GetAuraIcon(isPlaced and not IsOtherTab() and ResolveSpec() or nil,
                                effect.auraName)
    if iconTex and section.SetPreviewIcons then
        local isGlyph = (DF.ParseADFilterRef and DF:ParseADFilterRef(effect.auraName)) and true or false
        section:SetPreviewIcons({
            { texture = iconTex, coords = (not isGlyph) and { 0.08, 0.92, 0.08, 0.92 } or nil },
        })
    end
    section:SetTag(EffectTag(effect, indicatorGroup))
    -- The header greys with the feature, exactly as the section headers on every
    -- other converted page do.
    if not ctx.adEnabled and section.SetPreviewDimmed then section:SetPreviewDimmed(true) end

    -- The aura's own tracking warning, where the card put it: after the identity,
    -- before the actions.
    AttachWarningBadge(section, GetAuraWarningKey(
        (not IsOtherTab()) and ResolveSpec() or nil, effect.auraName), {
        point = "RIGHT", relativeTo = section, relativePoint = "RIGHT",
        offsetX = -76, offsetY = 0, size = 16,
    })

    -- ── THE HEADER'S TWO ACTIONS ──
    -- Delete is hidden for a grouped indicator, exactly as on the card: a layout
    -- group owns its members, and removing one is the group's own verb.
    local delBtn
    if not indicatorGroup then
        delBtn = GUI:CreateCloseButton(section, {
            size = 22,
            onClick = function()
                if isPlaced then
                    RemoveIndicatorInstance(effect.auraName, effect.indicatorID)
                else
                    local auraCfg = CurrentAuraPool()[effect.auraName]
                    if auraCfg then auraCfg[effect.typeKey] = nil end
                    S.CleanupAdHocAura(effect.auraName)
                end
                expandedCards[cardKey] = nil
                S.SwitchTab("effects")
                RefreshPlacedIndicators()
                RefreshPreviewEffects()
                -- Structural: the container rebuilds AND the buff row's dedup
                -- union shrinks, so the full path rather than a restyle.
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
            end,
        })
        delBtn:SetPoint("RIGHT", -6, 0)
        delBtn:SetFrameLevel(section:GetFrameLevel() + 2)
    end

    -- The eye: shown / hidden / cannot-show, on the raw config table.
    do
        local cfgTable = effect.config
        local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
        local eyeBtn = GUI:CreateGlyphButton(section, { size = 18 })
        if delBtn then
            eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        else
            eyeBtn:SetPoint("RIGHT", section, "RIGHT", -8, 0)
        end
        eyeBtn:SetFrameLevel(section:GetFrameLevel() + 2)
        local function shown() return not cfgTable or cfgTable.enabled ~= false end
        -- Tracks nothing = greyed, WITHOUT touching the stored value. A derived
        -- look, not a write: tick an id back on and the eye resumes reflecting
        -- what the user set.
        local function tracksNothing()
            return DF.ADPlacementTracksNothing
                and DF:ADPlacementTracksNothing((not IsOtherTab()) and ResolveSpec() or nil,
                        effect.auraName, cfgTable) or false
        end
        local function updateEyeIcon()
            local dead = tracksNothing()
            if dead then
                eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.3, 0.3, 0.3 })
            elseif shown() then
                eyeBtn:SetGlyph(mediaPath .. "visibility", { 0.95, 0.95, 0.95 })
            else
                eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.45, 0.45, 0.45 })
            end
            eyeBtn:SetGlyphHover(shown() and not dead)
            eyeBtn.tooltip = dead and L["Nothing ticked — this indicator will not show."] or nil
        end
        updateEyeIcon()
        eyeBtn:RegisterForClicks("LeftButtonUp")
        eyeBtn:SetScript("OnClick", function()
            if not cfgTable then return end
            cfgTable.enabled = (cfgTable.enabled == false) or nil
            updateEyeIcon()
            RefreshPlacedIndicators()
            RefreshPreviewEffects()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            local E = DF.AuraDesigner and DF.AuraDesigner.Engine
            if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
        end)
    end

    -- ☠ AND NOW SAY WHAT THE RIGHT END COST. The title and the tag run rightward
    -- from the arrow with no edge of their own, and everything above runs leftward
    -- from the other side; on the 850px island the two never met, and on the
    -- ~410px band a 640px window gives this page they do -- a long spell name ran
    -- straight under the eye and the delete. This is also what keeps the header's
    -- spell-icon swatch out from under the delete button, which it shared a right
    -- inset with. 96 clears the warning badge (-76 plus its 16), which is the
    -- furthest-in of the three; without one the two buttons are all there is.
    if section.SetHeaderRightInset then
        local badgeShown = section.dfWarningBadge and section.dfWarningBadge:IsShown()
        section:SetHeaderRightInset(badgeShown and 96 or (delBtn and 56 or 30))
    end

    Add(section, 36, "both")

    if not section.expanded then return end

    -- ── THE BAND OF ROWS ──
    -- Headerless: the section's own header is this effect's name, which is the
    -- Modules page's rule for a band inside a section.
    local band = GUI:CreateSettingsGroup(page.child, tools.BandWidth(), { chromeless = true })
    section:RegisterChild(band)

    local proxy = isPlaced
        and CreateInstanceProxy(effect.auraName, effect.indicatorID)
        or  CreateProxy(effect.auraName, effect.typeKey)
    -- ☠ THE ROW'S db IS THE PROXY, NOT DF.db[mode]. Everything behind these rows
    -- lives on ONE indicator record, and the proxy is what carries the phase-0
    -- defaults adapter (__dfDefaultsAdapter, AuraDesigner/UI/Groups.lua) that lets
    -- the diff engine answer "is this modified" for a record it otherwise knows
    -- nothing about. Handed the page db instead, every row's amber tick would be
    -- permanently dark and Reset Group would write nothing while saying it had.
    local RowProxy = function() return proxy end

    -- ☠ THE FEATURE SWITCH GREYS THE ROWS, NOT ONE SHEET OVER THE PAGE. The split
    -- panel drew a disabled overlay across its whole right half; a column of bands
    -- has no such surface, and the page's own state pass greys widgets that answer
    -- to disableOn -- which a popout row does and a plain band host does not. A
    -- dimmed row still OPENS (the kit's grey is alpha and a disabled toggle, not a
    -- dead frame), so the settings stay readable while they are switched off. The
    -- Resource Bar rule.
    local function AlwaysOff() return true end

    local rows = {}
    local function AddRow(label, build, opts)
        opts = opts or {}
        local mount, content = tools.PopoutContent(function(group, holder, reflow)
            build(group, holder, reflow)
        end)
        local row = band:AddWidget(GUI:CreatePopoutRow(page.child, {
            label   = label,
            title   = format("%s \226\128\148 %s", title, label),
            db      = RowProxy,
            -- Derived, never declared: the pane is built eagerly a line above, so
            -- the number on the badge is the number of controls actually in it. A
            -- literal here would be a second source of truth for a count that
            -- varies by client capability (the border toolkit's include set, the
            -- pandemic controls' 12.1 gate).
            count   = content and content.groupChildren and #content.groupChildren or nil,
            window  = DF.GUIFrame,
            clipTo  = page,
            build   = mount,
        }))
        if opts.hideOn then row.hideOn = opts.hideOn end
        if not ctx.adEnabled then row.disableOn = AlwaysOff end
        tools.ClaimKeys(row, content)
        tools.WireModifiedTick(row)
        tools.WireFooter(row, ApplyEffectGroup, RowProxy)
        rows[label] = row
        return row
    end

    -- ── FRAME-LEVEL: TRIGGERED BY, THEN PRIORITY ──
    -- The two blocks an effect carries that are not sections of BuildTypeContent.
    -- Each is one hand-anchored widget, so each is added to its pane as ONE child
    -- sized by what the shared builder reports.
    if not isPlaced then
        AddRow(L["Triggered By"], function(group, holder)
            local host = CreateFrame("Frame", nil, holder)
            -- ☠ SIZED BEFORE THE BUILDER RUNS. The trigger tags flow to the
            -- container's own width, read at BUILD time -- a host that had not been
            -- sized yet would report 0 and every tag would land on its own line.
            host:SetWidth(PopoutWidth())
            local h = S.BuildEffectTriggersBlock(host, effect, PopoutWidth(), 0)
            host:SetHeight(h + 12)   -- +12: the container's own top gap
            group:AddWidget(host, h + 12)
        end)
        AddRow(L["Priority"], function(group, holder)
            local host = CreateFrame("Frame", nil, holder)
            host:SetWidth(PopoutWidth())
            local h = S.BuildEffectPriorityBlock(host, effect, proxy, PopoutWidth(), 0)
            host:SetHeight(h)
            group:AddWidget(host, h)
        end)
    end

    -- ── OTHERS ONLY ──
    -- ☠ A CONTROL ROW, NOT A PANEL. One boolean, and a popout row's own tick
    -- column already IS that checkbox -- the Modules page's rule for a group with
    -- nothing in it but the switch. The trade is the group's two footer verbs,
    -- which for one boolean the modified dot on the control itself covers.
    if IsOtherTab() and effect.typeKey ~= "sound" then
        -- The page's STATE pass, never a rebuild: a rebuild here would retire the
        -- row the click landed on. Named once so the row and the search entry it
        -- registers run the same thing.
        local function OnOthersOnly()
            S.EffectOthersOnlyChanged(function() page:RefreshStates() end)
        end
        local ooRow = band:AddWidget(GUI:CreateControlRow(page.child, {
            label     = L["Others Only"],
            kind      = "checkbox",
            db        = RowProxy,
            key       = "othersOnly",
            tooltip   = L["Only show this effect for other players' casts of the buff."],
            onChanged = OnOthersOnly,
        }))
        if not ctx.adEnabled then ooRow.disableOn = AlwaysOff end
        -- `custom` is true: the value does not live in DF.db[key] but on one
        -- indicator record behind the proxy, which is what the registry has to be
        -- told or an inline search result would read and write the mode's profile.
        tools.RegisterControlRow(ooRow, "checkbox", "othersOnly", true, OnOthersOnly)
    end

    -- ── EVERY SECTION THE CARD WOULD HAVE BUILT ──
    -- Collect mode walks the SAME branches the card walks and hands back the same
    -- section bodies, unrun. Nothing here decides what an icon has and a bar does
    -- not; BuildTypeContent still does, in one place.
    local collect = {}
    -- The bar's expiry note links to Appearance. In this layout that destination
    -- is a sibling ROW rather than somewhere to scroll to, so the note is told
    -- how to reach it.
    collect.openSection = function(header)
        local r = rows[header]
        if r and r.OpenPopout then r:OpenPopout() end
    end
    -- ⚠ page.child AS THE HOST, AND IT IS NEVER TOUCHED. Collect mode builds
    -- nothing, sizes nothing and stamps nothing onto the host it is handed; the
    -- argument exists only because the section bodies read it, and each of them is
    -- re-pointed at its own pane before it runs.
    BuildTypeContent(page.child, effect.typeKey, effect.auraName,
                     PopoutWidth(), proxy, 0,
                     indicatorGroup, effect.indicatorID, collect)

    for _, sec in ipairs(collect) do
        AddRow(sec.header, sec.build, { hideOn = sec.hideOn })
    end

    Add(band, nil, "both")
end

-- ── THE EFFECTS TAB ──
local function BuildEffectsTabRows(ctx, shell)
    local page, tools, Add = ctx.page, ctx.tools, ctx.Add

    -- ── + ADD INDICATOR ──
    -- ☠ ONE ROW WHERE A 230px BLOCK STOOD. The three scope cards were permanent
    -- furniture at the top of this tab; they are now the second step inside this
    -- row's panel, behind the spell search that is the first (Cards.lua's
    -- S.BuildAddIndicatorPane). It holds no settings, so it takes neither a
    -- modified tick nor a footer -- the same rule the Members and Linked Filters
    -- rows follow.
    local addBand = GUI:CreateSettingsGroup(page.child, tools.BandWidth(), { chromeless = true })
    local addRow
    local addMount = tools.PopoutContent(function(g, holder)
        local pane = CreateFrame("Frame", nil, holder)
        pane:SetWidth(PopoutWidth())
        -- ☠ THE HEIGHT THE BUILDER ASKED FOR, REMEMBERED. Every SetHeight below
        -- is swallowed while `ready` is false -- which is the whole build -- so
        -- without keeping the number the AddWidget under it measured a pane that
        -- had never been sized and gave it a 1px slot. The panel opened EMPTY.
        local ready, wantH = false, nil
        S.BuildAddIndicatorPane(pane, {
            width = PopoutWidth(),
            -- ⚠ SILENT UNTIL THE PANE IS IN THE GROUP. The builder shows its
            -- first step as it finishes, and a height reported before AddWidget
            -- has run has no slot to land in: GUI:RelayoutHost would walk straight
            -- past the group this has not joined yet and re-run the PAGE's state
            -- pass in the middle of the page's own build.
            SetHeight = function(h)
                wantH = h
                if ready then GUI:RelayoutHost(pane, h) end
            end,
            Close     = function()
                if addRow and addRow.ClosePopout then addRow:ClosePopout("api") end
            end,
        })
        -- wantH FIRST: the builder reports through the callback, not by sizing the
        -- pane, so its own GetHeight is the fallback and not the answer.
        g:AddWidget(pane, max(wantH or pane:GetHeight() or 1, 1))
        ready = true
        -- And once the slot exists, honour anything the build asked for while it
        -- did not.
        if wantH then GUI:RelayoutHost(pane, wantH) end
    end)
    addRow = addBand:AddWidget(GUI:CreatePopoutRow(page.child, {
        label  = L["Add Indicator"],
        title  = L["Add Indicator"],
        window = DF.GUIFrame,
        clipTo = page,
        build  = addMount,
    }))
    if not ctx.adEnabled then addRow.disableOn = function() return true end end
    Add(addBand, nil, "both")

    -- ── THE ACTIVE INDICATORS HEADING, AND THE FILTER ON IT ──
    -- The same furniture the card layout puts above its list, mounted as one
    -- full-width object. The add BLOCK is skipped -- this layout has a row for it
    -- -- and the eight chips are skipped too.
    --
    -- ☠ THE CHIPS WERE A `Showing` POPOUT ROW FOR ONE RELEASE, AND THAT WAS 50px
    -- OF FURNITURE FOR ONE FILTER -- a whole plate and its gap, more than the 22px
    -- chip row it replaced (rework spec section 20's correction 2, which is where
    -- the honest chrome total went UP). They are a glyph on this caption now:
    -- right-aligned, opening the same panel the row opened. The all-rows rule is
    -- still satisfied -- the eight options are in a popout -- and the caption band
    -- is furniture the page was already paying for.
    --
    -- ⚠ AND THE GLYPH SAYS WHEN A FILTER IS ON. A filter control that looks
    -- identical whether you are showing everything or only Borders is how someone
    -- loses their indicators and concludes they were deleted, so the glyph accents
    -- AND names the filter beside itself whenever it is not All. See
    -- S.BuildEffectsHeadArea's filterGlyph arm.
    local pickerOpen
    GUI:AddDesignerLegacyTab(shell, function(host)
        host:SetWidth(tools.BandWidth())
        local yPos, taken = S.BuildEffectsHeadArea(host, -4,
                                                   { skipAddBlock = true, skipChips = true,
                                                     filterGlyph = true,
                                                     filterGlyphEnabled = ctx.adEnabled })
        pickerOpen = taken
        -- ⚠ ONLY THE PICKER ARM SIZES THE HOST ITSELF. The normal arm returns its
        -- running y and leaves the sizing to the caller, because inside the split
        -- panel the caller carried on adding effect cards below it.
        if not taken then host:SetHeight(max(-(yPos or 0) + 4, 1)) end
    end)
    if pickerOpen then return end

    local effects = CollectAllEffects()
    local filtered = {}
    for _, effect in ipairs(effects) do
        if S.activeFilter == "all" or effect.typeKey == S.activeFilter then
            filtered[#filtered + 1] = effect
        end
    end

    if #filtered == 0 then
        -- ⚠ THE EMPTY STATE IS A BANNER, NOT A CENTRED FONTSTRING. A column of
        -- bands has no half-panel to centre anything in, and CreateInfoBanner is
        -- the shared shape for "nothing here yet, and here is why".
        local spec = ResolveSpec()
        local specAuras = spec and DF.AuraDesigner.Adapter
            and DF.AuraDesigner.Adapter:GetTrackableAuras(spec)
        local text
        if not IsOtherTab() and (not spec or not specAuras or #specAuras == 0) then
            text = L["No trackable spells found for this spec.\n\nYou can select a different spec using the dropdown above."]
        elseif S.activeFilter == "all" then
            -- ⚠ NOT "pick a style above" ANY MORE. That sentence pointed at the
            -- three scope cards, which phase 5 moved into the Add Indicator row's
            -- panel; the split panel below still has them and still says it.
            text = L["No effects configured yet.\nUse Add Indicator above to place your first one."]
        else
            text = format(L["No %s effects configured."],
                          S.PLACED_TYPE_LABELS[S.activeFilter]
                          or S.FRAME_LEVEL_LABELS[S.activeFilter] or S.activeFilter)
        end
        local banner = GUI:CreateInfoBanner(page.child, { tone = "info" })
        banner:SetWidth(tools.BandWidth())
        banner:SetText(text)
        Add(banner, nil, "both")
        return
    end

    for _, effect in ipairs(filtered) do
        MountEffect(ctx, effect, shell)
    end
end

-- ============================================================
-- ONE LAYOUT GROUP'S ROWS
-- ------------------------------------------------------------
-- The same shape a placed effect takes (see MountEffect): the GROUP is a
-- collapsible SECTION whose header carries the identity -- its name, its
-- one-line summary, the eye and the delete -- and the rows in the band under it
-- each own one panel. The group itself is expand-only for the same reason an
-- effect is: it is a way in to five or ten groups, not a group, and the popout
-- system is deliberately ONE level deep.
--
-- ⚠ THE FOLD STATE IS expandedGroups, NOT collapsedGroups, and Toggle is
-- REPLACED rather than hooked. CreateCollapsibleSection persists its fold under
-- the section's TITLE TEXT, and these titles are USER-TYPED GROUP NAMES -- one
-- permanent profile key per group, forever, which is a schema change smuggled in
-- under "pure re-presentation". The state stays in the same in-memory table the
-- card layout used. Same trap MountEffect documents; the section factory has it
-- by default for anything with a user-derived title.
-- ============================================================

-- The pane's own env, the other half of Editor.lua's `place` seam: a card runs a
-- y cursor down its body, and a pane hands each widget to the pane's settings
-- group, which sizes and anchors it. Nothing else about a section body differs.
local function PaneEnv(g, holder, verbs)
    return {
        place = function(widget, height) g:AddWidget(widget, height) end,
        host  = holder,
        -- caption / bodyWidth are deliberately ABSENT: in a pane the popout row's
        -- own label is the caption, and the group owns the width.
        Rebuild = verbs.Rebuild,
        Redraw  = verbs.Redraw,
        Header  = verbs.Header,
    }
end

-- Everything a group's rows are built from, for both group stores. The two
-- differ in which sections they collect, which record their rows measure against
-- and what their headers say; the machinery below is one copy.
local function MountGroup(ctx, group, spec)
    local page, tools, Add = ctx.page, ctx.tools, ctx.Add
    local bandW = tools.BandWidth()
    local cardKey = spec.cardKey
    local record = spec.record

    local section = GUI:CreateCollapsibleSection(page.child, group.name, false, bandW)
    section.expanded = expandedGroups[cardKey] and true or false
    section.arrow:SetTexture(section.expanded
        and "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more"
        or  "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    section.Toggle = function(self)
        expandedGroups[cardKey] = not self.expanded or nil
        -- A rebuild, not a state pass: the rows under a collapsed group are not
        -- BUILT, so there is nothing for RefreshStates to reveal.
        if page.Refresh then page:Refresh() end
    end

    local function RefreshHeader()
        section.sectionTitleText = group.name
        section.title:SetText(group.name)
        section:SetTag(spec.Summary())
    end
    RefreshHeader()
    -- The header greys with the feature, exactly as every other converted page's
    -- section headers do.
    if not ctx.adEnabled and section.SetPreviewDimmed then section:SetPreviewDimmed(true) end

    -- ── THE HEADER'S TWO ACTIONS ── the card's own delete and eye.
    local delBtn = GUI:CreateCloseButton(section, { size = 22, onClick = spec.onDelete })
    delBtn:SetPoint("RIGHT", -6, 0)
    delBtn:SetFrameLevel(section:GetFrameLevel() + 2)

    if spec.showEye then
        local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
        local eyeBtn = GUI:CreateGlyphButton(section, { size = 18 })
        eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        eyeBtn:SetFrameLevel(section:GetFrameLevel() + 2)
        local function shown() return group.enabled ~= false end
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
        eyeBtn:SetScript("OnClick", function()
            group.enabled = (group.enabled == false) and true or false
            updateEyeIcon()
            spec.onEye()
        end)
    end

    -- The right end's cost -- see MountEffect. A group's title is a name the USER
    -- typed, up to thirty characters, so this header is the one most likely to
    -- reach the buttons.
    if section.SetHeaderRightInset then
        section:SetHeaderRightInset(spec.showEye and 56 or 30)
    end

    Add(section, 36, "both")

    if not section.expanded then return end

    -- ── THE BAND OF ROWS ──
    -- Headerless: the section's own header is this group's name, which is the
    -- Modules page's rule for a band inside a section.
    local band = GUI:CreateSettingsGroup(page.child, tools.BandWidth(), { chromeless = true })
    section:RegisterChild(band)

    -- ☠ THE ROW'S db IS A VIEW OF THE GROUP RECORD, NOT DF.db[mode]. Everything
    -- behind these rows lives on ONE group record, and the view is what carries
    -- the defaults adapter (AuraDesigner/UI/Groups.lua) that lets the diff engine
    -- answer "is this modified" for a table it otherwise knows nothing about.
    -- Handed the page db instead, every row's amber tick would be permanently
    -- dark and Reset Group would write nothing while saying it had.
    local function RowRecord() return record end
    local function AlwaysOff() return true end

    local function AddRow(label, build, rowDB, extra)
        local mount, content = tools.PopoutContent(build)
        local row = band:AddWidget(GUI:CreatePopoutRow(page.child, {
            label   = label,
            title   = format("%s \226\128\148 %s", group.name, label),
            db      = rowDB or RowRecord,
            -- Derived, never declared: the pane is built eagerly a line above, so
            -- the badge counts the controls actually in it.
            count   = content and content.groupChildren and #content.groupChildren or nil,
            window  = DF.GUIFrame,
            clipTo  = page,
            build   = mount,
        }))
        if not ctx.adEnabled then row.disableOn = AlwaysOff end
        tools.ClaimKeys(row, content, extra)
        -- ⚠ NO TICK AND NO FOOTER WHERE THE ROW HOLDS NO SETTINGS. Members,
        -- Linked Filters and the Global tab's three action groups are lists of
        -- VERBS -- there is nothing for a modified tick to report and nothing for
        -- Reset Group to reset, and a footer that quietly wrote nothing is the
        -- exact failure this phase was blocked on.
        if rowDB ~= false then
            tools.WireModifiedTick(row)
            tools.WireFooter(row, spec.Apply, rowDB or RowRecord)
        end
        return row
    end

    -- ── THE GROUP'S NAME ──
    -- ☠ A CONTROL ROW, NOT A PANEL. One edit box, and the Modules page's rule for
    -- a group with nothing in it but the control is a plate of its own. The card
    -- draws it as a captioned edit box at the top of its body; here the header
    -- above already shows the name, and this is where it is changed.
    local nameRow = band:AddWidget(GUI:CreateControlRow(page.child, {
        label      = L["Name"],
        kind       = "editbox",
        db         = RowRecord,
        key        = "name",
        maxLetters = 30,
        onChanged  = function()
            RefreshHeader()
            RefreshPlacedIndicators()
        end,
    }))
    if not ctx.adEnabled then nameRow.disableOn = AlwaysOff end
    -- `custom` is true: the value does not live in DF.db[key] but on one group
    -- record behind the view, which is what the registry has to be told or an
    -- inline search result would read and write the mode's profile.
    tools.RegisterControlRow(nameRow, "editbox", "name", true)

    -- ── ONE ROW PER SECTION ──
    -- The list is NOT declared here: it is whatever the collector returns, which
    -- is the SAME list the card runs down its own cursor, so the two layouts
    -- cannot disagree about which blocks a group has.
    local verbs = {
        -- A LIST moved. Both layouts redraw the page; the panel goes with it,
        -- which is honest -- what was being edited is gone.
        Rebuild = function() S.SwitchTab("layout") end,
        -- A VALUE moved and the widgets around it must re-read their greying. A
        -- rebuild here would retire the tick the user just clicked, so the page's
        -- STATE pass runs instead and the panes re-flow themselves.
        Redraw  = function()
            tools.ReflowMounted()
            page:RefreshStates()
        end,
        Header  = RefreshHeader,
    }
    for _, sec in ipairs(spec.sections) do
        AddRow(sec.header, function(g, holder)
            sec.build(PaneEnv(g, holder, verbs))
        end, sec.rowDB)
    end

    -- ── OTHERS ONLY ──
    -- ☠ A CONTROL ROW, NOT A PANEL, for the reason the effect rows' copy is: one
    -- boolean, and a popout row's own tick column already IS that checkbox.
    if spec.othersOnly then
        local function OnOthersOnly()
            RefreshHeader()
            RefreshPlacedIndicators()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            local E = DF.AuraDesigner and DF.AuraDesigner.Engine
            if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
            page:RefreshStates()
        end
        local ooRow = band:AddWidget(GUI:CreateControlRow(page.child, {
            label     = L["Others Only"],
            kind      = "checkbox",
            db        = RowRecord,
            key       = "othersOnly",
            tooltip   = L["Only show other players' casts of these buffs."],
            onChanged = OnOthersOnly,
        }))
        if not ctx.adEnabled then ooRow.disableOn = AlwaysOff end
        tools.RegisterControlRow(ooRow, "checkbox", "othersOnly", true, OnOthersOnly)
    end

    -- ── APPEARANCE ──
    -- ⚠ FIVE SIBLING ROWS, NOT A NESTED SECTION. The card draws Appearance /
    -- Border / Duration Text / Stack Count / Duration Bar as five collapsible
    -- boxes inside its body; a second collapsible section inside this one would
    -- be two levels of fold, and RegisterChild carries exactly one -- collapsing
    -- the outer would hide the inner header and leave its band on the page. So
    -- the five arrive as five rows in the same band, which is what an effect's
    -- ten sections already do.
    if spec.appearance then
        local styleSections = AddGroupAppearanceSection(page.child, group, PopoutWidth(), 0,
                                                        cardKey, {})
        local styleProxy = styleSections.proxy
        local function StyleDB() return styleProxy end
        for _, sec in ipairs(styleSections) do
            AddRow(sec.header, function(g, holder, reflow)
                sec.build(g, holder, reflow)
            end, StyleDB)
        end
    end

    Add(band, nil, "both")
end

-- ── THE LAYOUT GROUPS TAB ──
local function BuildLayoutTabRows(ctx, shell)
    local page, tools, Add = ctx.page, ctx.tools, ctx.Add
    local isDebuffs = IsDebuffTab()

    -- The intro, the choice cards and the dedup hint -- the same furniture the
    -- card layout puts above its list, mounted as one full-width object. One
    -- definition, two hosts, exactly as the Effects tab's head area is.
    GUI:AddDesignerLegacyTab(shell, function(host)
        host:SetWidth(tools.BandWidth())
        local yPos
        if isDebuffs then
            yPos = S.BuildDebuffGroupsHeadArea(host, -4)
        else
            yPos = S.BuildLayoutGroupsHeadArea(host, -4)
        end
        host:SetHeight(max(-(yPos or 0) + 4, 1))
    end)

    local groups = isDebuffs and DebuffGroupsRead() or CurrentLayoutGroups()

    -- ⚠ NO SEPARATE EMPTY STATE. The head area above already IS one when the
    -- list is empty: it swaps in the teaching sentence and the choice cards that
    -- create the first group, which is what an empty state is for. A banner under
    -- it would repeat the same sentence twice on the same screen.
    if #groups == 0 then return end

    for _, group in ipairs(groups) do
        if isDebuffs then
            local cardKey = "dgroup:" .. group.id
            P.EnsureDebuffSelection(group)
            local sections = P.CollectDebuffGroupSections(group)
            -- The Categories row measures itself against the SELECTION block,
            -- which is its own record with its own controls; Placement and Growth
            -- against the group.
            local selView = DebuffSelectionView(group.selection)
            sections[1].rowDB = function() return selView end
            local function StructuralDebuffGroupRefresh()
                S.SwitchTab("layout")
                RefreshPlacedIndicators()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
            end
            MountGroup(ctx, group, {
                cardKey    = cardKey,
                record     = DebuffGroupRecordView(group),
                sections   = sections,
                appearance = true,
                showEye    = true,
                Summary    = function() return S.DebuffGroupSummary(group) end,
                Apply      = function()
                    RefreshPlacedIndicators()
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                    if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
                end,
                onDelete = function()
                    DeleteDebuffGroup(group.id)
                    StructuralDebuffGroupRefresh()
                end,
                onEye = StructuralDebuffGroupRefresh,
            })
        else
            local isFilterGroup = (group.kind == "filter")
            MountGroup(ctx, group, {
                cardKey    = GroupExpandKey(group.id),
                record     = GroupRecordView(group),
                -- `true`: the row layout draws Others Only itself, as a control
                -- row, so the Growth section must not draw it as well.
                sections   = P.CollectLayoutGroupSections(group, true),
                appearance = isFilterGroup,
                showEye    = isFilterGroup,
                othersOnly = isFilterGroup and IsOtherTab(),
                Summary    = function() return S.LayoutGroupSummary(group) end,
                Apply      = function()
                    RefreshPlacedIndicators()
                    local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                    if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
                end,
                onDelete = function()
                    DeleteLayoutGroup(group.id)
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                    -- Deleting a group deletes its member indicators -- the same
                    -- structural refresh as the effect row's delete.
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                    if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
                end,
                onEye = function()
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                    if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
                end,
            })
        end
    end
end

-- ── THE GLOBAL TAB ──
-- Seven rows, one per block the split panel drew as a captioned box. Four of
-- them hold settings and take a tick and a footer; three hold ACTIONS -- an
-- import, a link out, a copy and a reset -- and deliberately take neither.
local function BuildGlobalTabRows(ctx, shell)
    local page, tools, Add = ctx.page, ctx.tools, ctx.Add

    -- ☠ page.child AS THE HOST, AND IT IS NEVER TOUCHED. Collect mode builds
    -- nothing, sizes nothing and stamps nothing onto the host it is handed; the
    -- argument exists only because the section bodies read it, and each of them
    -- is re-pointed at its own pane before it runs.
    local sections = BuildGlobalView(page.child, {})

    local band = GUI:CreateSettingsGroup(page.child, tools.BandWidth(), { chromeless = true })

    -- What a write behind any of these rows costs. Global defaults reach EVERY
    -- indicator, so this is the full teardown the card's own proxy writes run.
    local function ApplyGlobalGroup()
        RefreshPlacedIndicators()
        RefreshPreviewEffects()
        RefreshLiveFramesThrottled()
        local E = DF.AuraDesigner and DF.AuraDesigner.Engine
        if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
    end

    local function AlwaysOff() return true end

    for _, sec in ipairs(sections) do
        local mount, content = tools.PopoutContent(function(g, holder)
            sec.build(g, holder)
        end)
        local row = band:AddWidget(GUI:CreatePopoutRow(page.child, {
            label   = sec.header,
            title   = format("%s \226\128\148 %s", L["Global"], sec.header),
            db      = sec.db and function() return sec.db end or nil,
            count   = content and content.groupChildren and #content.groupChildren or nil,
            window  = DF.GUIFrame,
            clipTo  = page,
            build   = mount,
        }))
        if not ctx.adEnabled then row.disableOn = AlwaysOff end
        -- ⚠ `extra` IS NOT A CONVENIENCE HERE. The Sound Alerts pair is bound
        -- through custom get/set, so ClaimKeys' walk cannot see either key -- and
        -- a row that claimed nothing would have a dark tick and a Reset Group that
        -- wrote nothing while saying it had.
        tools.ClaimKeys(row, content, sec.extra)
        if sec.db then
            tools.WireModifiedTick(row)
            tools.WireFooter(row, ApplyGlobalGroup, function() return sec.db end)
        end
    end

    Add(band, nil, "both")
end

-- ============================================================
-- DF.BuildAuraDesignerPage's POPOUT ARM
-- ------------------------------------------------------------
-- The whole page, as bands in the harness's own column: banner, canvas, pool
-- strip, tab strip, then the active tab. Every object is built at
-- tools.BandWidth() and added "both", so the page has one left edge and one
-- right edge and needs no minimum window width of its own.
-- ============================================================
P.BuildAuraDesignerRowsPage = function(page, db, Add, AddSpace)
    S.page, S.db = page, db
    S.rowsMode = true

    -- A shared picker left open on a PREVIOUS build dies with it; drop the handle
    -- so CloseADPicker cannot poke a stale overlay.
    S.adPickerDirty  = false
    S.adPickerHandle = nil
    -- ☠ AND THE SPLIT PANEL'S OWN SURFACES GO WITH IT. They are what the picker
    -- covers, what SwitchTab clears and what the scroll helpers reach for; left
    -- pointing at a retired island they would be poked, shown and hidden by code
    -- that has no idea it is looking at a dead frame.
    S.leftPanel, S.rightPanel = nil, nil
    S.tabBar, S.tabScrollFrame, S.tabContentFrame = nil, nil, nil
    S.activeTab      = S.activeTab or "effects"
    S.activeBuffTab  = S.activeBuffTab or "my"
    S.activeFilter   = S.activeFilter or "all"
    if S.activeTab == "effects" and IsDebuffTab() then S.activeTab = "layout" end

    local tools = GUI:CreatePopoutPageTools(page)
    if not tools then return end   -- classic; the caller took the island arm

    -- ☠ FROM THE MODE, NOT THE PRESET. The enable switch writes the MODE's own
    -- key; reading it off the preset is what made the tick un-stick once already.
    local adEnabled = DF.IsAuraDesignerEnabledForMode
        and DF:IsAuraDesignerEnabledForMode((GUI and GUI.SelectedMode) or "party")

    local ctx = { page = page, db = db, Add = Add, AddSpace = AddSpace,
                  tools = tools, adEnabled = adEnabled }

    GUI:BuildDesignerShell(page, {
        tools    = tools,
        Add      = Add,
        AddSpace = AddSpace,

        banner = function(parent)
            local banner = CreateEnableBanner(parent)
            S.enableBanner = banner
            banner:SetWidth(tools.BandWidth())

            -- ☠ ROW 2 IS THE TEMPLATE BAR'S ALONE, AND SPEC IS NOT COMING BACK TO
            -- IT. The plan for this pass was to fold the scope row away by putting
            -- Spec here beside Template -- two labelled pickers rather than the
            -- three that were refused before. Measured at the window's 520px
            -- MINIMUM it does not fit either: the band is ~301px, this bar spans it
            -- less its 10px insets, and 281px carrying two captions, two caption
            -- gaps, the overflow glyph and the gap between the halves leaves ~82px
            -- per opener -- below the ~113px section 17 of the rework spec already
            -- called "usable, not comfortable", and worse than the ~118px Spec has
            -- today. See S.BuildScopeRow for the full arithmetic.

            -- Which named preset this mode uses, plus library management. Rides
            -- row 2 of the banner, as it does in the split-panel layout.
            if GUI.CreateDesignerPresetBar then
                local presetBar = GUI:CreateDesignerPresetBar(banner, {
                    kind = "aura",
                    iconButtons = true,
                    -- ☠ THE FOUR ACTIONS BECOME ONE GLYPH. Four labelled buttons
                    -- were ~100px of fixed row against a caption and a dropdown;
                    -- behind one menu they are 22. With Spec on a band of its own
                    -- that 78px goes to the Template dropdown, which is what the
                    -- ~113px measurement at the window's minimum was asking for.
                    overflowActions = true,
                    getMode = function() return (GUI and GUI.SelectedMode) or "party" end,
                    onChange = function()
                        -- Deferred so the bar is not torn down from inside its own
                        -- click handler.
                        if C_Timer and C_Timer.After then
                            C_Timer.After(0, function()
                                if page.Refresh then page:Refresh() end
                                DF:InvalidateAuraLayout()
                                DF:UpdateAllFrames()
                                local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                                if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
                            end)
                        end
                    end,
                })
                presetBar:SetPoint("LEFT", banner, "LEFT", 10, -18)
                presetBar:SetPoint("RIGHT", banner, "RIGHT", -10, -18)
                banner.presetBar = presetBar
            end
            return banner, 68
        end,

        -- The pool, as three folder tabs joined to the preview panel below them.
        -- ABOVE the canvas rather than below it: the panel is what separates them
        -- from the sub-tab strip, which is the whole reason they can be tabs again.
        canvasTabs = { height = POOLTABS_H,
                       build = function(host) S.BuildPoolTabs(host) end },

        canvas = function(host, shell)
            -- Lifted as-is: the same anatomy, the same nine anchor dots, the same
            -- RefreshGeometry. `compact` is about the canvas's own FURNITURE, not
            -- its content -- see CreateFramePreview.
            -- hideLabel: the band above this one is the fold header, and it is
            -- already captioned FRAME PREVIEW.
            S.framePreview = CreateFramePreview(host, 0, nil, { compact = true, hideLabel = true })
            -- ☠ WHAT THE ISLAND'S REUSE GUARD USED TO DO, AT THE RIGHT SCOPE.
            -- That guard rebuilt the whole page when the frame's size, the active
            -- auto-layout or the preview scale had moved, because a rebuild was
            -- the only way to re-read them. The page harness caches a valid build
            -- across revisits, so nothing would re-read them at all -- and the
            -- only thing that actually needs to is the canvas, which has a verb
            -- for exactly that.
            host:HookScript("OnShow", function()
                if S.framePreview and S.framePreview.RefreshGeometry then
                    S.framePreview.RefreshGeometry()
                end
                RefreshPlacedIndicators()
                RefreshPreviewEffects()
            end)
            -- ...and the other half of the island's own pair: leaving the page with
            -- no refresh pass would leave the rendered preview pool's border
            -- animations ticking on the external driver. OnHide fires on effective
            -- visibility loss, so closing the window or switching page reaches it.
            host:HookScript("OnHide", P.ClearPlacedIndicators)
            -- The scale slider's own callback, both halves of it. The canvas
            -- reports what it now needs and the shell moves the bands below --
            -- so scaling the mock up pushes the page down instead of painting
            -- over the scope row.
            S.framePreview.onWantHeight = function(want)
                if shell and shell.SetCanvasHeight then shell.SetCanvasHeight(want) end
            end
            return S.framePreview
        end,
        canvasHeight = function() return P.CanvasWantedHeight(true) end,
        -- ☠ A LITERAL KEY, NEVER THE TITLE. CreateCollapsibleSection persists a
        -- fold under the section's title text unless told otherwise, and
        -- "FRAME PREVIEW" is a localised string -- a German client would write a
        -- second profile key and a reworded heading would orphan the first. This
        -- is the same trap the effect and group sections had to sidestep.
        canvasFold = { title = L["FRAME PREVIEW"], collapseKey = "ad_canvas" },

        strips = {
            { height = SCOPEROW_H, build = function(host) S.BuildScopeRow(host) end },
        },

        tabs = {
            { key = "effects", label = L["Effects"], accent = nil,
              -- Effects is buff-pool-only: category groups have no per-spell
              -- placed indicators, so it frosts on the Debuffs pool.
              disabled = function() return IsDebuffTab() end,
              tooltip  = { title = L["Effects"], onlyWhenDisabled = true,
                           lines = { L["Not available for Debuffs. Use Layout Groups instead."] } } },
            { key = "layout",  label = L["Layout Groups"], accent = { r = 0.91, g = 0.66, b = 0.25 } },
            { key = "global",  label = L["Global"],        accent = { r = 0.51, g = 0.86, b = 0.51 } },
        },
        activeTab = S.activeTab,
        onTab     = function(key) S.SwitchTab(key) end,

        buildTab = function(key, shell)
            if key == "effects" then
                BuildEffectsTabRows(ctx, shell)
            elseif key == "layout" then
                BuildLayoutTabRows(ctx, shell)
            elseif key == "global" then
                BuildGlobalTabRows(ctx, shell)
            end
        end,
    })

    RefreshPlacedIndicators()
    RefreshPreviewEffects()
end
