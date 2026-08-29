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

local BUFFTAB_H = 30
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
-- THE POOL STRIP
-- ------------------------------------------------------------
-- My Buffs / Debuffs / Any Buff, plus the spec dropdown on the right end.
-- ONE definition, two hosts: a slice of S.mainFrame in the split-panel layout
-- (Editor.lua), a band in this one. The three pools differ on two axes the
-- labels can't carry, so each tab explains itself on hover.
-- ============================================================
S.BuildPoolStrip = function(buffTabBar)
    local MAIN_TAB_DEFS = {
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
    wipe(mainTabButtons)
    local prevMainBtn
    for _, def in ipairs(MAIN_TAB_DEFS) do
        local btn = CreateFrame("Button", nil, buffTabBar, "BackdropTemplate")
        GUI:StyleButton(btn, { height = BUFFTAB_H - 4, text = def.label, font = "DFFontHighlight" })
        btn.Text:ClearAllPoints()
        btn.Text:SetPoint("CENTER", 0, 0)
        btn:SetWidth(max(btn.Text:GetStringWidth() + 28, 96))
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

    -- Relocated spec dropdown (right end of the strip)
    local stripSpecLabel = buffTabBar:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    stripSpecLabel:SetText(L["Spec:"])
    stripSpecLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    S.specDropdown, S.specDropdownUpdate = CreateSpecDropdown(buffTabBar)
    S.specDropdown:SetSize(165, 22)
    S.specDropdown:SetPoint("RIGHT", buffTabBar, "RIGHT", -5, 0)
    stripSpecLabel:SetPoint("RIGHT", S.specDropdown, "LEFT", -4, 0)
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

    -- The add block, the ACTIVE INDICATORS heading, the chips and the Other Buffs
    -- hint -- the same furniture the card layout puts above its list, mounted as
    -- one full-width object. The add flow is a later phase of the rework; when it
    -- lands, it lands for both layouts at once because there is one copy of it.
    local pickerOpen
    GUI:AddDesignerLegacyTab(shell, function(host)
        host:SetWidth(tools.BandWidth())
        local yPos, taken = S.BuildEffectsHeadArea(host, -4)
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
            text = L["No effects configured yet.\nPick a style above to get started."]
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
            -- Which named preset this mode uses, plus library management. Rides
            -- row 2 of the banner, as it does in the split-panel layout.
            if GUI.CreateDesignerPresetBar then
                local presetBar = GUI:CreateDesignerPresetBar(banner, {
                    kind = "aura",
                    iconButtons = true,
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

        canvas = function(host, shell)
            -- Lifted as-is: the same anatomy, the same nine anchor dots, the same
            -- RefreshGeometry. `compact` is about the canvas's own FURNITURE, not
            -- its content -- see CreateFramePreview.
            S.framePreview = CreateFramePreview(host, 0, nil, { compact = true })
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
            -- over the pool strip.
            S.framePreview.onWantHeight = function(want)
                if shell and shell.SetCanvasHeight then shell.SetCanvasHeight(want) end
            end
            return S.framePreview
        end,
        canvasHeight = function() return P.CanvasWantedHeight(true) end,

        strips = {
            { height = BUFFTAB_H, build = function(host) S.BuildPoolStrip(host) end },
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
                -- ⚠ STILL THE SPLIT PANEL'S OWN CONTENT, as one full-width object.
                -- Layout Groups and Global convert in the next phase; until then the
                -- page has to be fully usable, so they render exactly what they
                -- rendered before. S.tabContentFrame is what those builders write
                -- into, so the host stands in for it.
                GUI:AddDesignerLegacyTab(shell, function(host)
                    host:SetWidth(tools.BandWidth())
                    S.tabContentFrame = host
                    if IsDebuffTab() then S.BuildDebuffGroupsTab() else S.BuildLayoutGroupsTab() end
                end)
            elseif key == "global" then
                GUI:AddDesignerLegacyTab(shell, function(host)
                    host:SetWidth(tools.BandWidth())
                    S.tabContentFrame = host
                    S.BuildGlobalTab()
                end)
            end
        end,
    })

    RefreshPlacedIndicators()
    RefreshPreviewEffects()
end
