-- Part 3 of the Aura Designer editor, split from Options.lua.
-- Aliases of objects the first part created; they add no state.
local addonName, DF = ...
local L = DF.L
local GUI = DF.GUI
local Adapter = DF.AuraDesigner.Adapter
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv
local C_TEXT_DIM = GUI.Colors.textDim
local OPTS = P.OPTS
local ResolveSpec = P.ResolveSpec
local IsOtherTab = P.IsOtherTab
local CurrentAuraPool = P.CurrentAuraPool
local OtherPoolDisplayName = P.OtherPoolDisplayName
local CopyIndicatorAppearance = P.CopyIndicatorAppearance
local RefreshLiveFramesThrottled = P.RefreshLiveFramesThrottled
local AddExpiryAlertControls = P.AddExpiryAlertControls
local AddDurationColorsLink = P.AddDurationColorsLink
local CreateProxy = P.CreateProxy

-- ============================================================
-- INDICATOR TYPE WIDGET BUILDER
-- (Tile strip removed in v4 redesign)
-- ============================================================


-- layoutGroup: optional layout group table; if set, anchor/offset controls are replaced with a note
-- indicatorID: optional indicator ID for placed indicators (used by Copy From)
local function BuildTypeContent(parent, typeKey, auraName, width, optProxy, yOffset, layoutGroup, indicatorID)
    local proxy = optProxy or CreateProxy(auraName, typeKey)
    local contentWidth = width or 248
    -- widgets[] entries are {widget, height} so the reflow path can use
    -- group.calculatedHeight (current after a LayoutChildren) while
    -- non-group widgets fall back to the stored at-build-time height.
    local widgets = {}
    local startY = 10 + (yOffset or 0)  -- top padding + optional offset
    local totalHeight = startY

    -- P4.7 (12.1 GUI status overlays): collected here so the block pass at the
    -- end of BuildTypeContent can frost the effect-settings groups the factory
    -- can't (yet) drive, WITHOUT touching the trigger tags above (built into
    -- `parent` before this function runs — the working "which aura" layer).
    -- swmCheck is captured for the surgical Show-When-Missing block. See block pass below.
    local swmCheck, wholeBarCheck, swmGroup, durColorByTimeCtl

    local function AddWidget(widget, height)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -totalHeight)
        if widget.SetWidth then widget:SetWidth(contentWidth - 10) end
        tinsert(widgets, { widget = widget, height = height or 30 })
        totalHeight = totalHeight + (height or 30)
    end

    -- Reflow all widgets in this BuildTypeContent's stack.  When a group's
    -- LayoutChildren updates its own height (e.g. Border's animation
    -- widgets show/hide), the siblings below were anchored at FIXED y
    -- positions based on the old height — they stay put, causing overlap
    -- (group grew) or large gap (group shrank).  Walk the list re-anchor
    -- each widget at the running total height, reading the current
    -- group.calculatedHeight for groups so the new layout flows correctly.
    -- The host container's height is updated too so any parent scroll
    -- range stays accurate.
    parent.dfAD_ReflowWidgets = function()
        local y = startY
        for _, entry in ipairs(widgets) do
            local w = entry.widget
            local h
            if w.calculatedHeight then
                -- SettingsGroup tracks its current height after LayoutChildren.
                h = w.calculatedHeight
            else
                h = entry.height
            end
            w:ClearAllPoints()
            w:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -y)
            y = y + h
        end
        parent:SetHeight(y)
    end

    local function AddGroup(header, buildFn, showSummary)
        local group = GUI:CreateSettingsGroup(parent, contentWidth - 10, {
            collapsible = true,
            showSummary = showSummary or false,
        })
        group.padding = 10   -- match the main Options groups' inner padding (airier scale)
        group:AddWidget(GUI:CreateHeader(parent, header), GUI.RowHeight.sectionHeader)
        buildFn(group)
        local h = group:LayoutChildren()
        AddWidget(group, h)
        -- Tag the Show-When-Missing group so the surgical 12.1 block can find it.
        if header == L["Show When Missing"] then swmGroup = group end
        return group
    end


    -- ── COPY FROM (placed indicators only: icon, square, bar) ──
    if indicatorID and (typeKey == "icon" or typeKey == "square" or typeKey == "bar") then
        local copyContainer = CreateFrame("Frame", nil, parent)
        copyContainer:SetHeight(36)

        local copyLabel = copyContainer:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(copyLabel, 8, "")
        copyLabel:SetPoint("TOPLEFT", 1, -1)
        copyLabel:SetText(L["COPY APPEARANCE FROM"])
        copyLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        local capturedAuraName = auraName
        local capturedIndicatorID = indicatorID
        local capturedTypeKey = typeKey

        -- Build the list of other placed indicators of the same type as the
        -- dropdown's options (rebuilt on each open via optionsFunc so newly-added
        -- indicators appear). Keyed by a synthetic id -> a captured source table;
        -- picking one copies its appearance. The opener stays "Select indicator..."
        -- (it's an action picker, not a value selector), achieved by a customGet
        -- that always returns that label string (no matching option key).
        local copySources = {}
        local function BuildCopyFromOptions()
            wipe(copySources)
            local isOther = IsOtherTab()
            local spec = (not isOther) and ResolveSpec() or nil
            local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
            local displayNames = {}
            if trackable then
                for _, info in ipairs(trackable) do
                    displayNames[info.name] = info.display
                end
            end

            -- Sources come from the SAME pool as the destination card (the
            -- active tab's) — CopyIndicatorAppearance resolves both ends
            -- through the pool-routed GetIndicatorByID.
            local sources = {}
            for srcAura, auraCfg in pairs(CurrentAuraPool(spec)) do
                if type(auraCfg) == "table" and auraCfg.indicators then
                    for _, ind in ipairs(auraCfg.indicators) do
                        if ind.type == capturedTypeKey then
                            -- Skip self
                            if not (srcAura == capturedAuraName and ind.id == capturedIndicatorID) then
                                tinsert(sources, {
                                    auraName = srcAura,
                                    displayName = isOther and OtherPoolDisplayName(srcAura)
                                        or displayNames[srcAura] or srcAura,
                                    indicatorID = ind.id,
                                })
                            end
                        end
                    end
                end
            end
            sort(sources, function(a, b) return a.displayName < b.displayName end)

            local options = { _order = {} }
            for i, src in ipairs(sources) do
                local key = "src" .. i
                copySources[key] = src
                options[key] = { text = src.displayName }
                options._order[i] = key
            end
            return options
        end

        local copyDrop = GUI:CreateDropdown(
            copyContainer, "", BuildCopyFromOptions(),
            nil, nil, nil,
            function() return L["Select indicator..."] end,   -- customGet (static opener)
            function(key)                                      -- customSet (action)
                local src = copySources[key]
                if src then
                    CopyIndicatorAppearance(src.auraName, src.indicatorID, capturedAuraName, capturedIndicatorID)
                    DF:AuraDesigner_RefreshPage()
                end
            end,
            { inline = true, optionsFunc = BuildCopyFromOptions }
        )
        copyDrop:SetPoint("TOPLEFT", 0, -12)
        copyDrop:SetPoint("RIGHT", copyContainer, "RIGHT", 0, 0)
        copyDrop:SetHeight(20)

        AddWidget(copyContainer, 38)
    end

    -- Color picker callback shorthand — refreshes both the AD preview and live frames
    local function RPL() if S.RefreshPreviewLightweight then S.RefreshPreviewLightweight() end RefreshLiveFramesThrottled() end

    -- Shared Duration Bar section for the icon / square placed indicators — both carry
    -- durationBar* keys and the strip hangs off the slot edge regardless of shape. Same
    -- control set as the filter-group card and the buff/debuff rows (one shared spec
    -- builder, DF:BuildDurationBarSpec, reads these keys). Greys IMPERATIVELY: AD cards
    -- have no disableOn/RefreshStates loop (unlike the row pages), so the enable gate
    -- AND the curve-mode dimming of Texture/Bar Color are driven by hand from the Enable
    -- and Color Mode callbacks. Structural writes (enable/position/height/gap/colorMode)
    -- rebuild via the proxy's __newindex → RefreshLiveFramesThrottled, exactly like the
    -- Show Duration toggle; only the colour pickers need RPL (sub-table writes skip
    -- __newindex — see the Border group's note).
    local function AddDurationBarGroup()
        AddGroup(L["Duration Bar"], function(g)
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
            g:AddWidget(GUI:CreateCheckbox(parent, L["Enable Duration Bar"], proxy, "durationBarEnabled", UpdateBarGrey), 28)
            local function barChild(widget, h) g:AddWidget(widget, h); dbWidgets[#dbWidgets + 1] = widget; return widget end
            barChild(GUI:CreateDropdown(parent, L["Position"], { BOTTOM = L["Bottom"], TOP = L["Top"] }, proxy, "durationBarPosition"), 54)
            barChild(GUI:CreateSlider(parent, L["Height"], 1, 12, 1, proxy, "durationBarHeight"), 54)
            barChild(GUI:CreateSlider(parent, L["Gap"], 0, 10, 1, proxy, "durationBarGap"), 54)
            barChild(GUI:CreateDropdown(parent, L["Color Mode"],
                DF:GetDurationBarColorModes(),
                proxy, "durationBarColorMode", UpdateBarGrey), 54)
            -- A curve mode brings its own ramp texture and forces a white tint, so these
            -- two do nothing while it is selected — grey them (curveGated) when it is.
            local texW = barChild(GUI:CreateTextureDropdown(parent, L["Bar Texture"], proxy, "durationBarTexture"), 54)
            local colW = barChild(GUI:CreateColorPicker(parent, L["Bar Color"], proxy, "durationBarColor", true, RPL, RPL, true), 28)
            curveGated[texW] = true; curveGated[colW] = true
            barChild(GUI:CreateColorPicker(parent, L["Background Color"], proxy, "durationBarBGColor", true, RPL, RPL, true), 28)
            barChild(GUI:CreateCheckbox(parent, L["Reverse Fill"], proxy, "durationBarReverseFill"), 28)
            UpdateBarGrey()
        end)
    end

    if typeKey == "icon" then
        -- Position
        AddGroup(L["Position"], function(g)
            if layoutGroup then
                local groupNote = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
                groupNote:SetText(format(L["Position managed by: %s"], layoutGroup.name or L["Layout Group"]))
                g:AddWidget(groupNote, 18)
            else
                g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "offsetX"), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "offsetY"), 54)
            end
        end)
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateSlider(parent, L["Size"], 8, 64, 1, proxy, "size"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 3.0, 0.05, proxy, "scale"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0, 1, 0.05, proxy, "alpha"), 54)
            g:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, proxy, "frameLevel")), 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], proxy, "hideSwipe"), 28)
            -- Text-only mode: the icon TEXTURE is hidden, so a border (static OR
            -- expiring) would frame nothing. Rebuild the S.page on toggle so the
            -- Border group + the expiring-border thickness control hide/show
            -- (gated on proxy.hideIcon below) — matching the runtime, which
            -- force-disables both borders in this mode.
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Icon (Text Only)"], proxy, "hideIcon", function()
                DF:AuraDesigner_RefreshPage()
            end), 28)
        end)
        -- Show When Missing
        AddGroup(L["Show When Missing"], function(g)
            local desatCb
            local function UpdateDesatState()
                if not desatCb then return end
                if proxy.showWhenMissing then
                    desatCb:SetAlpha(1)
                    desatCb:EnableMouse(true)
                else
                    desatCb:SetAlpha(0.4)
                    desatCb:EnableMouse(false)
                end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                UpdateDesatState()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end), 28)
            desatCb = GUI:CreateCheckbox(parent, L["Desaturate When Missing"], proxy, "missingDesaturate", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(desatCb, 28)
            UpdateDesatState()
        end)
        -- Border (Stage 5.1c — unified controls via CreateBorderControls).
        -- Show / Thickness / Inset are the same widgets as before; the helper
        -- adds Style / Texture / Color / Gradient / Shadow / BlendMode /
        -- Offset / Alpha on top.  Animation, classColor, roleColor, and the
        -- colorByTime checkbox are deliberately omitted — animation isn't
        -- wired through AD's expiring system yet, class/role don't fit aura
        -- indicators (the indicator's job is to show aura state, not unit
        -- identity), and AD's Expiring section already covers "colour by
        -- time remaining" implicitly through its own colour curve.
        -- Text-only mode hides the icon texture, so the whole Border group is
        -- hidden (the runtime force-disables the border there too).
        if not proxy.hideIcon then
        AddGroup(L["Border"], function(g)
            GUI:CreateBorderControls(g, proxy, "", {
                parent  = parent,
                include = {
                    inset = true, offset = true, blendMode = true,
                    gradient = true, shadow = true, alpha = true,
                },
                -- IMPORTANT: AD's per-aura proxy only triggers
                -- RefreshLiveFramesThrottled + S.RefreshPreviewLightweight
                -- on direct key assignment (proxy.X = v) via __newindex.
                -- CreateColorPicker and the Border Alpha slider mutate
                -- SUB-TABLE fields (proxy.BorderColor.a = v) which reads
                -- through __index then writes to the returned table — no
                -- __newindex fires, no refresh runs, and both the live
                -- frame AND the AD preview window stay on the pre-edit
                -- colour until /reload.
                --
                -- RPL (defined above in BuildTypeContent) runs both the
                -- preview refresh and the throttled live-frame refresh, so
                -- colour-picker / alpha-slider / size-drag updates land
                -- everywhere consistently within the 100ms debounce.
                fullUpdate    = RPL,
                lightUpdate   = RPL,
                lightColors   = RPL,
                -- refreshStates re-evaluates hideOn on the Border group's
                -- widgets and then reflows the sibling groups below in the
                -- card body so the Expiring / Duration Text / Stack Count
                -- groups slide up or down to track the Border group's new
                -- height.  Without the reflow, the Border group's internal
                -- LayoutChildren updates its own height but the siblings
                -- stay at fixed y positions — animation widgets surface
                -- and overlap Expiring, or hide and leave a gap above
                -- Expiring.  dfAD_ReflowWidgets is set on the BuildTypeContent
                -- parent and walks the whole widget stack.
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then
                        parent.dfAD_ReflowWidgets()
                    end
                end,
                sizeMin = 1, sizeMax = 5, sizeStep = 1,
            })
        end)
        end  -- if not proxy.hideIcon (text-only hides the Border group)
        -- Expiring (moved up next to Border — the border's expiring colour and
        -- the per-icon effects all key off the same threshold, so grouping
        -- them adjacent reads more naturally than burying Expiring at the
        -- bottom of the panel.)
        -- Icon: single Expiring Colour, Whole Alpha Pulse + Bounce effects.
        -- Duration Text
        AddGroup(L["Duration Text"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], proxy, "showDuration"), 28)
            -- Icon-sized formats only — Number "14" / Seconds "14s" / Percent "45%";
            -- FULL and the combined "12s (45%)" live on the BAR card, which has the
            -- width. Forward-declared UpdateHideAboveState: the dropdown re-greys
            -- Hide Above (percent formats can't compose with it), assigned below.
            local UpdateHideAboveState
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Format"], {
                NUMBER = L["Number"], SHORT = L["Seconds"], PERCENT = L["Percent"],
                _order = { "NUMBER", "SHORT", "PERCENT" },
            }, proxy, "durationFormat", function() if UpdateHideAboveState then UpdateHideAboveState() end end), 54)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Duration Font"], proxy, "durationFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Duration Scale"], 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], proxy, "durationOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "durationOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "durationX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "durationY"), 54)
            durColorByTimeCtl = GUI:CreateCheckbox(parent, L["Color by Time Remaining"], proxy, "durationColorByTime")
            g:AddWidget(durColorByTimeCtl, 28)
            AddDurationColorsLink(g, parent)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Duration Text Color"], proxy, "durationColor", true, RPL, RPL, true), 28)
            local hideAboveSlider, hideAboveCheck
            -- ASSIGNS the forward-declared local from the Duration Format dropdown
            -- above (a `local function` here would shadow it and strand the
            -- dropdown's callback on nil). Also greys the pair while a
            -- percent-family format is picked — Hide Above's seconds threshold
            -- can't band a percent-sampled formatter (see GetDurationFormatFields).
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
            hideAboveCheck = GUI:CreateCheckbox(parent, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", UpdateHideAboveState)
            g:AddWidget(hideAboveCheck, 28)
            hideAboveSlider = GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold")
            g:AddWidget(hideAboveSlider, 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration on Permanent Auras"], proxy, "durationHideOnPermanent"), 28)
            UpdateHideAboveState()
        end)
        -- Expiration: the frame-anchored Expiry Alert ELEMENT (own section —
        -- distinct from the sound "Expire Alert" group on the sound card).
        AddGroup(L["Expiration"], function(g)
            AddExpiryAlertControls(g, parent, proxy)
        end)
        -- Stack Count
        AddGroup(L["Stack Count"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Stacks"], proxy, "showStacks"), 28)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Stack Font"], proxy, "stackFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Stack Scale"], 0.5, 2.0, 0.1, proxy, "stackScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Stack Outline"], proxy, "stackOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "stackOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Stack Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "stackAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "stackX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "stackY"), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Stack Text Color"], proxy, "stackColor", true, RPL, RPL, true), 28)
        end)
        -- Duration Bar (native SetDurationBar strip — shared with the square card)
        AddDurationBarGroup()

    elseif typeKey == "square" then
        -- Position
        AddGroup(L["Position"], function(g)
            if layoutGroup then
                local groupNote = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
                groupNote:SetText(format(L["Position managed by: %s"], layoutGroup.name or L["Layout Group"]))
                g:AddWidget(groupNote, 18)
            else
                g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "offsetX"), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "offsetY"), 54)
            end
        end)
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateSlider(parent, L["Size"], 8, 64, 1, proxy, "size"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 3.0, 0.05, proxy, "scale"), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
            g:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0, 1, 0.05, proxy, "alpha"), 54)
            g:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, proxy, "frameLevel")), 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], proxy, "hideSwipe"), 28)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Icon (Text Only)"], proxy, "hideIcon"), 28)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end), 28)
        end)
        -- Border (Stage 5.2 — unified controls via CreateBorderControls).
        -- Same full toolkit as the icon's base border: Style / Texture / Colour
        -- / Gradient / Shadow / Blend / Offset / Alpha + Animation.  The
        -- square's expiring system tints the FILL (not the border), so the
        -- icon's expiring-border overrides are intentionally NOT added here.
        AddGroup(L["Border"], function(g)
            GUI:CreateBorderControls(g, proxy, "", {
                parent  = parent,
                include = {
                    inset = true, offset = true, blendMode = true,
                    gradient = true, shadow = true, alpha = true,
                },
                fullUpdate    = RPL,
                lightUpdate   = RPL,
                lightColors   = RPL,
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then
                        parent.dfAD_ReflowWidgets()
                    end
                end,
                sizeMin = 1, sizeMax = 5, sizeStep = 1,
            })
        end)
        -- Expiring (moved up next to Border — matches the icon indicator's
        -- panel ordering. Border colour, fill pulsate, alpha pulse, and bounce
        -- all key off the same threshold; grouping them adjacent to Border
        -- reads more naturally than burying Expiring at the bottom.)
        -- Square: separate fill + border Expiring colours (alpha handle edits the
        -- BORDER colour); Fill Pulsate + Whole Alpha Pulse + Bounce effects.
        -- Duration Text
        AddGroup(L["Duration Text"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], proxy, "showDuration"), 28)
            -- Icon-sized formats only (see the icon card's Duration Format note).
            local UpdateHideAboveState
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Format"], {
                NUMBER = L["Number"], SHORT = L["Seconds"], PERCENT = L["Percent"],
                _order = { "NUMBER", "SHORT", "PERCENT" },
            }, proxy, "durationFormat", function() if UpdateHideAboveState then UpdateHideAboveState() end end), 54)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Duration Font"], proxy, "durationFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Duration Scale"], 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], proxy, "durationOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "durationOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "durationX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "durationY"), 54)
            durColorByTimeCtl = GUI:CreateCheckbox(parent, L["Color by Time Remaining"], proxy, "durationColorByTime")
            g:AddWidget(durColorByTimeCtl, 28)
            AddDurationColorsLink(g, parent)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Duration Text Color"], proxy, "durationColor", true, RPL, RPL, true), 28)
            local hideAboveSlider, hideAboveCheck
            -- ASSIGNS the forward-declared local from the Duration Format dropdown
            -- above (a `local function` here would shadow it and strand the
            -- dropdown's callback on nil). Also greys the pair while a
            -- percent-family format is picked — Hide Above's seconds threshold
            -- can't band a percent-sampled formatter (see GetDurationFormatFields).
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
            hideAboveCheck = GUI:CreateCheckbox(parent, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", UpdateHideAboveState)
            g:AddWidget(hideAboveCheck, 28)
            hideAboveSlider = GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold")
            g:AddWidget(hideAboveSlider, 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration on Permanent Auras"], proxy, "durationHideOnPermanent"), 28)
            UpdateHideAboveState()
        end)
        -- Expiration: the frame-anchored Expiry Alert ELEMENT (own section —
        -- distinct from the sound "Expire Alert" group on the sound card).
        AddGroup(L["Expiration"], function(g)
            AddExpiryAlertControls(g, parent, proxy)
        end)
        -- Stack Count
        AddGroup(L["Stack Count"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Stacks"], proxy, "showStacks"), 28)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Stack Font"], proxy, "stackFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Stack Scale"], 0.5, 2.0, 0.1, proxy, "stackScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Stack Outline"], proxy, "stackOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "stackOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Stack Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "stackAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "stackX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "stackY"), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Stack Text Color"], proxy, "stackColor", true, RPL, RPL, true), 28)
        end)
        -- Duration Bar (native SetDurationBar strip — shared with the icon card)
        AddDurationBarGroup()

    elseif typeKey == "bar" then
        -- Position
        AddGroup(L["Position"], function(g)
            if layoutGroup then
                local groupNote = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
                groupNote:SetText(format(L["Position managed by: %s"], layoutGroup.name or L["Layout Group"]))
                g:AddWidget(groupNote, 18)
            else
                g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "offsetX"), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "offsetY"), 54)
            end
        end)
        -- Size & Orientation
        AddGroup(L["Size & Orientation"], function(g)
            g:AddWidget(GUI:CreateDropdown(parent, L["Orientation"], OPTS.BAR_ORIENT_OPTIONS, proxy, "orientation", function()
                local w = proxy.width
                local h = proxy.height
                proxy.width = h
                proxy.height = w
                local mw = proxy.matchFrameWidth
                local mh = proxy.matchFrameHeight
                proxy.matchFrameWidth = mh
                proxy.matchFrameHeight = mw
                DF:AuraDesigner_RefreshPage()
            end), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Width"], 0, 200, 1, proxy, "width"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Height"], 1, 30, 1, proxy, "height"), 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Match Frame Width"], proxy, "matchFrameWidth"), 28)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Match Frame Height"], proxy, "matchFrameHeight"), 28)
        end)
        -- Texture & Colors  (group captured to scroll to; the Color Mode widget to flash)
        local colorModeDrop
        local texColorsGroup = AddGroup(L["Texture & Colors"], function(g)
            -- Colour Mode: Static uses Bar Texture + Fill Color; a curve (DF / Classic) swaps in a
            -- green->red ramp the drain reveals — so the bar reddens as the aura expires — and
            -- forces a white tint, so those two grey out (curveGated) while a curve is selected.
            local curveGated = {}
            local function UpdateColorModeGrey()
                local curve = DF:IsDurationBarCurveMode(proxy.barColorMode)
                for w in pairs(curveGated) do if w.SetEnabled then w:SetEnabled(not curve) end end
            end
            colorModeDrop = g:AddWidget(GUI:CreateDropdown(parent, L["Color Mode"],
                DF:GetDurationBarColorModes(), proxy, "barColorMode", UpdateColorModeGrey), 54)
            local texW = g:AddWidget(GUI:CreateTextureDropdown(parent, L["Bar Texture"], proxy, "texture"), 54)
            local colW = g:AddWidget(GUI:CreateColorPicker(parent, L["Fill Color"], proxy, "fillColor", true, RPL, RPL, true), 28)
            curveGated[texW] = true; curveGated[colW] = true
            g:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], proxy, "bgColor", true, RPL, RPL, true), 28)
            g:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0, 1, 0.05, proxy, "alpha"), 54)
            g:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, proxy, "frameLevel")), 54)
            UpdateColorModeGrey()   -- initial grey for the curve-gated Texture / Fill Color
        end)
        -- Border (Stage 5.3 — unified controls via CreateBorderControls).
        -- Full toolkit (Style / Texture / Colour / Gradient / Shadow / Blend /
        -- Inset / Alpha + Animation).  No offset (the bar has its own X/Y) and
        -- no class/role (it's an aura bar, not unit identity).  The bar's
        -- expiring tints the FILL via its colour curve, so the icon/square
        -- expiring-border overrides are intentionally not added here.
        AddGroup(L["Border"], function(g)
            GUI:CreateBorderControls(g, proxy, "", {
                parent  = parent,
                include = {
                    inset = true, blendMode = true, gradient = true,
                    shadow = true, alpha = true,
                },
                fullUpdate    = RPL,
                lightUpdate   = RPL,
                lightColors   = RPL,
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then
                        parent.dfAD_ReflowWidgets()
                    end
                end,
                sizeMin = 1, sizeMax = 5, sizeStep = 1,
            })
        end)
        -- Duration Text
        AddGroup(L["Duration Text"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], proxy, "showDuration"), 28)
            -- The BAR is the wide surface, so the whole format family fits here:
            -- the icon-sized three plus FULL ("14 Seconds") and the combined
            -- Seconds + Percent ("12s (45%)" — 68914 multi-component text, #5).
            local UpdateHideAboveState
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Format"], {
                NUMBER = L["Number"], SHORT = L["Seconds"], FULL = L["Full"],
                PERCENT = L["Percent"], SECONDS_PERCENT = L["Seconds + Percent"],
                _order = { "NUMBER", "SHORT", "FULL", "PERCENT", "SECONDS_PERCENT" },
            }, proxy, "durationFormat", function() if UpdateHideAboveState then UpdateHideAboveState() end end), 54)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Duration Font"], proxy, "durationFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Duration Scale"], 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], proxy, "durationOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "durationOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "durationX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "durationY"), 54)
            durColorByTimeCtl = GUI:CreateCheckbox(parent, L["Color by Time Remaining"], proxy, "durationColorByTime")
            g:AddWidget(durColorByTimeCtl, 28)
            AddDurationColorsLink(g, parent)
            local hideAboveSlider, hideAboveCheck
            -- ASSIGNS the forward-declared local from the Duration Format dropdown
            -- above (a `local function` here would shadow it and strand the
            -- dropdown's callback on nil). Also greys the pair while a
            -- percent-family format is picked — Hide Above's seconds threshold
            -- can't band a percent-sampled formatter (see GetDurationFormatFields).
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
            hideAboveCheck = GUI:CreateCheckbox(parent, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", UpdateHideAboveState)
            g:AddWidget(hideAboveCheck, 28)
            hideAboveSlider = GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold")
            g:AddWidget(hideAboveSlider, 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration on Permanent Auras"], proxy, "durationHideOnPermanent"), 28)
            UpdateHideAboveState()
        end)
        -- Expiration: a bar carries its own colour-by-remaining-time (the Duration Bar Color Mode
        -- reddens the fill as it drains, secret-safe and full-size), so the |T Border/Tint aren't
        -- offered here — only a Text/Glyph alert. A note whose click jump-scrolls the card up to
        -- the Color Mode. (A full InfoBanner link-banner can't live in this AD card — html needs
        -- a post-SetWidth reflow the card's static-height path disables — so the whole note is the
        -- click target, with "Color Mode" tinted to signal it, like the cross-S.page links.)
        AddGroup(L["Expiration"], function(g)
            -- Note with a jump-link: only "Color Mode" is clickable — clicking scrolls the card
            -- up to Texture & Colors and flashes it. GUI:CreateLink = fixed-layout inline links
            -- (safe in the reflowing card); GUI:LinkToSetting = scroll + "show me" flash. The |c
            -- placeholder only satisfies the markup parser; CreateLink themes the link itself.
            local function scrollToTexColors()
                if not (S.tabScrollFrame and texColorsGroup and texColorsGroup.GetTop) then return end
                local sfTop, gTop = S.tabScrollFrame:GetTop(), texColorsGroup:GetTop()
                if not (sfTop and gTop) then return end
                local target = S.tabScrollFrame:GetVerticalScroll() + (sfTop - gTop) - 8
                local maxS = S.tabScrollFrame:GetVerticalScrollRange() or 0
                S.tabScrollFrame:SetVerticalScroll(math.max(0, math.min(maxS, target)))
            end
            local link = format("|cffffffff|HdfADScroll:texcolors|h%s|h|r", L["Color Mode"])
            -- Fixed-layout note: hand it the group's inner width so its wrapped (2-line) height is
            -- known before AddWidget — else it falls back to a fixed slot the text overflows.
            local innerW = math.max(40, (g:GetWidth() or 260) - 2 * (g.padding or 10))
            local note = GUI:CreateLink(parent, format(L["For expiry colour, set the %s in Texture & Colors."], link), {
                width = innerW,
                onLinkClick = function()
                    -- Scroll the section into view, but FLASH the specific Color Mode widget
                    -- (LinkToSetting flashes target.widget — pass the group instead to flash the
                    -- whole section).
                    GUI:LinkToSetting({ widget = colorModeDrop or texColorsGroup, scrollTo = scrollToTexColors,
                        flash = { border = true } })   -- a single control: fill + outline
                end,
            })
            g:AddWidget(note, note.layoutHeight or 34)
            AddExpiryAlertControls(g, parent, proxy, { border = false, tint = false, match = false })
        end)

    elseif typeKey == "border" then
        -- Appearance — full DF.Border toolkit (Stage 5.4).  The legacy 5
        -- styles are now combinations: Solid = Style SOLID; Glow = Style
        -- TEXTURE + DF Glow; Dashed/Animated = Border Thickness 0 + DF Dash
        -- (speed 0 / >0); Corners = Border Thickness 0 + Corners Only.
        -- include offset too — this border covers the whole frame, so nudging
        -- it can be useful.  No class/role (it's an aura indicator).
        AddGroup(L["Appearance"], function(g)
            GUI:CreateBorderControls(g, proxy, "", {
                parent  = parent,
                include = {
                    inset = true, offset = true, blendMode = true,
                    gradient = true, shadow = true, alpha = true,
                },
                fullUpdate    = RPL,
                lightUpdate   = RPL,
                lightColors   = RPL,
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then parent.dfAD_ReflowWidgets() end
                end,
                sizeMin = 0, sizeMax = 8, sizeStep = 1,
            })
            -- Draw order: lift this border above the frame's own class/role
            -- border so it fully covers it (on by default).  Off tucks it back
            -- underneath the frame border (the pre-5.4 stacking).
            -- WIRED 2026-07-25 (was frosted as "engine-managed, not wired yet"). The frame's own
            -- class/role border is a DF.Border child at frame+10, and the AD border container was
            -- pinned at exactly +10 too -- same level, so which one won came down to creation
            -- order. buildBorderConfig now resolves this flag to +11 (above) or +9 (below), and
            -- the flag rides the border structSig so toggling it rebuilds at the new offset.
            g:AddWidget(GUI:CreateCheckbox(parent, L["Draw above frame border"], proxy, "drawAboveFrameBorder", RPL), 28)
            swmCheck = GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(swmCheck, 28)
        end)
        -- Expiring — full parity with icon/square (Stage 5.4): master enable +
        -- State Overrides (border thickness / colour / alpha / animation swap)
        -- + the existing Pulsate.  The Expiring Animation lets the border swap
        -- effect below threshold (e.g. solid → marching DF Dash).
        -- Bar: single Expiring Colour, thicker max (8), a duration-priority row,
        -- and no Icon-Effects (bars don't pulse/bounce the whole icon).
        -- The border type draws no fill, so the expiring "tint" overlay has nothing
        -- to tint and ApplyBorderToOverlay never calls SetupExpiringTint — hide the
        -- otherwise-dead "Show Expiring Tint" / "Tint Color" controls for this type.

    elseif typeKey == "healthbar" then
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateDropdown(parent, L["Mode"], OPTS.HEALTHBAR_MODE_OPTIONS, proxy, "mode", function()
                -- Rebuild so the Blend % slider's hideOn re-evaluates and the
                -- group's height recomputes for the new visible-widget set.
                DF:AuraDesigner_RefreshPage()
            end), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
            local blendSlider = GUI:CreateSlider(parent, L["Blend %"], 0, 1, 0.05, proxy, "blend")
            -- hideOn is re-evaluated on every LayoutChildren pass, so the slider
            -- stays correctly hidden in Replace mode across GUI reopens. A manual
            -- :Hide() would be clobbered by LayoutChildren's unconditional :Show().
            blendSlider.hideOn = function() return (proxy.mode or "Replace") == "Replace" end
            g:AddWidget(blendSlider, 54)
            -- Tint-mode only: tint the WHOLE bar (incl. missing health) instead of
            -- just the current-health portion. Hidden in Replace mode (there the bar
            -- IS the indicator, so this would hide health loss). Same hideOn as Blend.
            wholeBarCheck = GUI:CreateCheckbox(parent, L["Tint Entire Bar"], proxy, "tintWholeBar", RPL)
            wholeBarCheck.hideOn = function() return (proxy.mode or "Replace") == "Replace" end
            g:AddWidget(wholeBarCheck, 28)
            swmCheck = GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(swmCheck, 28)
        end)

    elseif typeKey == "background" then
        -- Appearance — mirrors Health Bar Color. A colour overlay over the frame
        -- background (visible in the missing-health area). Replace = opaque cover;
        -- Tint = blend × colour alpha so the normal background shows through.
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateDropdown(parent, L["Mode"], OPTS.HEALTHBAR_MODE_OPTIONS, proxy, "mode", function()
                DF:AuraDesigner_RefreshPage()
            end), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
            local blendSlider = GUI:CreateSlider(parent, L["Blend %"], 0, 1, 0.05, proxy, "blend")
            blendSlider.hideOn = function() return (proxy.mode or "Tint") == "Replace" end
            g:AddWidget(blendSlider, 54)
            swmCheck = GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(swmCheck, 28)
        end)

    elseif typeKey == "nametext" then
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
        end)

    elseif typeKey == "healthtext" then
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
        end)


    elseif typeKey == "sound" then
        -- Enable checkbox
        AddGroup(L["Sound Alert"], function(g)
            -- Group-only warning banner
            do
                local topSpacer = CreateFrame("Frame", nil, parent)
                topSpacer:SetHeight(4)
                g:AddWidget(topSpacer, 4)

                local banner = GUI:CreateInfoBanner(parent, {
                    tone = "caution",
                    text = L["Sound alerts only work when you are in a group."],
                })
                banner:SetWidth(contentWidth - 10)
                g:AddWidget(banner, banner.layoutHeight)

                local spacer = CreateFrame("Frame", nil, parent)
                spacer:SetHeight(6)
                g:AddWidget(spacer, 6)
            end

            -- Other Buffs: the on-apply sound path has no caster filter
            -- (AddAuraAppliedSound), so an other-pool alert also fires for the
            -- player's OWN cast — and for a spell that My Buffs also tracked,
            -- both pools' sounds would fire. Surface it (B1 concern 2).
            if IsOtherTab() then
                local obBanner = GUI:CreateInfoBanner(parent, {
                    tone = "info",
                    text = L["Sound alerts play when anyone gains this buff, including your own casts."],
                })
                obBanner:SetWidth(contentWidth - 10)
                g:AddWidget(obBanner, obBanner.layoutHeight)
                local obSpacer = CreateFrame("Frame", nil, parent)
                obSpacer:SetHeight(6)
                g:AddWidget(obSpacer, 6)
            end

            local soundOn = proxy.enabled ~= false
            g:AddWidget(GUI:CreateCheckbox(parent, L["Enable Sound Alert"], proxy, "enabled", function()
                -- Stop sound immediately when disabled
                if not proxy.enabled and DF.AuraDesigner.SoundEngine then
                    DF.AuraDesigner.SoundEngine:StopAura(auraName)
                end
                DF:AuraDesigner_RefreshPage()
            end), 28)

            -- The flat sound below is the APPLIED sound (native Added trigger). This toggle
            -- silences it independently of the Buff-Dropped / Stack-Gained events below.
            if proxy.appliedEnabled == nil then proxy.appliedEnabled = true end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Play when the buff is applied"], proxy, "appliedEnabled", function()
                DF:AuraDesigner_RefreshPage()
            end), 28)

            -- Sound picker (searchable scrollable dropdown)
            local soundDD = GUI:CreateSoundDropdown(parent, L["Sound"], proxy, "soundLSMKey", function()
                -- Update soundFile path when LSM key changes
                local path = DF:GetSoundPath(proxy.soundLSMKey)
                if path then
                    proxy.soundFile = path
                end
            end)
            g:AddWidget(soundDD, 54)

            -- Custom file path (overrides LSM selection)
            local soundPathEB = GUI:CreateEditBox(parent, L["Custom Sound Path"], proxy, "soundFile", nil, 280)
            g:AddWidget(soundPathEB, 44)

            -- Preview button
            local previewBtn = GUI:CreateButton(parent, L["Preview Sound"], 120, 22, function()
                local soundFile = DF:GetSoundPath(proxy.soundLSMKey) or proxy.soundFile
                if not soundFile or soundFile == "" then
                    DF:Say(L["No sound file selected. Choose a sound from the dropdown or enter a custom path."])
                    return
                end
                local volume = proxy.volume or 0.8
                if DF.AuraDesigner.SoundEngine then
                    local willPlay = DF.AuraDesigner.SoundEngine:PlayWithVolume(soundFile, volume)
                    if not willPlay then
                        DF:Say(format(L["Sound file could not be played: %s"], tostring(soundFile)))
                    end
                end
            end)
            g:AddWidget(previewBtn, 28)

            -- Volume slider
            local volumeSlider = GUI:CreateSlider(parent, L["Volume"], 0, 1, 0.05, proxy, "volume")
            g:AddWidget(volumeSlider, 54)

            -- Grey out sound sub-controls when sound alert is disabled
            if not soundOn then
                soundDD:SetAlpha(0.4)
                soundDD:EnableMouse(false)
                soundPathEB:SetAlpha(0.4)
                soundPathEB:EnableMouse(false)
                previewBtn:SetAlpha(0.4)
                previewBtn:EnableMouse(false)
                volumeSlider:SetAlpha(0.4)
                volumeSlider:EnableMouse(false)
            end
        end)

        -- Buff-Dropped + Stack-Gained sounds (native Removed / ApplicationsIncreased
        -- triggers, 12.1). Each has its OWN sound, independently enabled. Distinct from the
        -- blocked Missing Trigger (fires-while-absent) and Expire Alert (near-expiry
        -- threshold), which still need sealed presence / remaining-time reads. On a pre-
        -- rename client the triggers are absent — the group shows a note and the sound no-ops.
        local newSoundTriggers = (C_UnitAuras and C_UnitAuras.AddAuraSound
            and Enum and Enum.UnitAuraSoundTrigger) and true or false
        local function AddEventSoundGroup(header, subKey, enableLabel)
            AddGroup(header, function(g)
                proxy[subKey] = proxy[subKey] or {}
                local ec = proxy[subKey]
                g:AddWidget(GUI:CreateCheckbox(parent, enableLabel, ec, "enabled", function()
                    DF:AuraDesigner_RefreshPage()
                end), 28)
                local dd = GUI:CreateSoundDropdown(parent, L["Sound"], ec, "soundLSMKey", function()
                    local path = DF:GetSoundPath(ec.soundLSMKey)
                    if path then ec.soundFile = path end
                end)
                g:AddWidget(dd, 54)
                local prev = GUI:CreateButton(parent, L["Preview Sound"], 120, 22, function()
                    local sf = DF:GetSoundPath(ec.soundLSMKey) or ec.soundFile
                    if not sf or sf == "" then
                        DF:Say(L["No sound file selected. Choose a sound from the dropdown or enter a custom path."])
                        return
                    end
                    if DF.AuraDesigner.SoundEngine then
                        DF.AuraDesigner.SoundEngine:PlayWithVolume(sf, proxy.volume or 0.8)
                    end
                end)
                g:AddWidget(prev, 28)
                if not newSoundTriggers then
                    g:AddWidget(GUI:CreateNote(parent,
                        L["Needs the current game build — these sound triggers aren't available on this client yet."],
                        { width = contentWidth - 20 }), 40)
                end
                if not (ec.enabled == true) then
                    dd:SetAlpha(0.4); dd:EnableMouse(false)
                    prev:SetAlpha(0.4); prev:EnableMouse(false)
                end
            end)
        end
        AddEventSoundGroup(L["Buff Dropped"], "dropped", L["Enable Buff-Dropped Sound"])
        AddEventSoundGroup(L["Stack Gained"], "stackGained", L["Enable Stack-Gained Sound"])


    end

    -- ============================================================
    -- 12.1 AURA-SYSTEM STATUS OVERLAYS (P4.7 GUI pass)
    -- Frost the AD effect-settings the 12.1 Blizzard aura system can't drive.
    -- Every block gates on DF:FactoryOwnsAD(d). Only
    -- the settings GROUPS built above are targeted — the trigger tags (the
    -- working "which aura" layer) live in `parent` above `startY` and are left
    -- alone. "roadmap" = temporary (delete the single call site when the port
    -- lands); "limitation" = permanent (secret-value casualty).
    -- ============================================================

    if typeKey == "icon" or typeKey == "square" then
        -- P4.3/P4.5 SHIPPED: icon/square render on the container engine (native icon / solid
        -- fill + cooldown + stacks + border + position), AND Show When Missing now renders via
        -- the read-free missing-mode container (static spell icon / colour square while absent).
        -- The whole-type roadmap and the Show-When-Missing roadmap overlays are gone. Two
        -- surgical blocks remain:
        --   * Expiring -- REMOVED 2026-07-25. The whole group was remaining-time-driven,
        --     unreadable on the container path, so it is gone rather than frosted. The
        --     12.1-safe replacement is the DF.Expiration engine (the Expiry Alert group).
        --   * Min Stacks to Show — REMOVED 2026-07-25 (was a permanent limitation, then a
        --     confirmed no-op). Stack counts render on the native no-formatter path (a
        --     formatter would receive the SECRET application count and trap — see
        --     Features/Auras.lua's stacks-formatter warning), so a custom minimum other than
        --     the native "shown at >1" is not expressible. The control, its key and its
        --     defaults are gone rather than frosted.
        --   * Duration "Colour by Time" — P4.4 SHIPPED: the duration text now colours by
        --     time via the native bucket formatter (C-side |c escapes), so the roadmap
        --     overlay is gone and the control is fully editable under the factory.
    elseif typeKey == "bar" then
        -- P4.4 SHIPPED: the bar renders on the container engine (native SetDurationBar fill
        -- + texture/colour/orientation + border + duration text). The whole-type roadmap
        -- overlay is gone. One surgical block remains:
        --   * Expiring -- REMOVED 2026-07-25. The whole group was remaining-time-driven,
        --     unreadable on the container path, so it is gone rather than frosted. The
        --     12.1-safe replacement is the DF.Expiration engine (the Expiry Alert group).
    elseif typeKey == "sound" then
        -- P4.5 SHIPPED: the sound indicator plays natively via C_UnitAuras.AddAuraSound.
        -- The Sound Alert group (picker / volume / preview) and the per-event groups
        -- (Applied / Buff Dropped / Stack Gained) are all live and unblocked.
        -- REMOVED 2026-07-25 -- Missing Trigger and Expire Alert. "Alert WHILE the buff is
        -- absent" is presence-driven and no native hook fires during absence; "alert as the
        -- buff FADES" is remaining-time-driven. Both were permanently frosted, and Expire
        -- Alert's intent is now served natively by Buff Dropped (the Removed trigger), so
        -- the groups and their ten inert keys are gone rather than left as dead controls.
    elseif typeKey == "nametext" or typeKey == "healthtext" then
        -- RECOVERED (colour-by-cover): the base Color works — the Text Designer keeps a
        -- glyph-identical coloured cover in sync with the real element (Render mirrors)
        -- and the aura slot's secret visibility shows it on presence. Two surgical blocks:
        --   * Show When Missing is not built for text covers at all - the checkbox is
        --     simply never created for them. A cover is SetAllPoints onto the real
        --     FontString, so its screen rect belongs to the text it mirrors; missing mode
        --     hides by MOVING a badge, so parking/pushing could never change what shows.
        --     (Same control SHIPPED for border/healthbar/background, whose art really does
        --     live inside the window.) Candidate path if it is ever wanted:
        --     SetAlphaFromBoolean(presence, 0, 255) on the mirror - on SimpleRegion as well
        --     as SimpleFrame, AllowedWhenTainted, and taking both alphas makes inversion
        --     free. Open question is sourcing `presence` as a SECRET BOOLEAN we can pass
        --     through without reading: an unrun in-game probe.
        --   * Expiring -- REMOVED 2026-07-25. The whole group was remaining-time-driven,
        --     unreadable on the container path, so it is gone rather than frosted. The
        --     12.1-safe replacement is the DF.Expiration engine (the Expiry Alert group).
    elseif typeKey == "healthbar" or typeKey == "background" or typeKey == "border" then
        -- Base effect settings (colour / mode / style) work on the container
        -- engine. Two surgical blocks on top:
        --   * Expiring -- REMOVED 2026-07-25. The whole group was remaining-time-driven,
        --     unreadable on the container path, so it is gone rather than frosted. The
        --     12.1-safe replacement is the DF.Expiration engine (the Expiry Alert group).
        --   * Show When Missing — P4.5 SHIPPED: the effect now renders via the read-free
        --     missing-mode container (tint / ring shown while the buff is absent), so the
        --     roadmap overlay is gone and the checkbox is fully editable under the factory.
        --   * Tint Entire Bar (healthbar only) — NO LONGER blocked. The filled health-mirror
        --     bar makes the current-health-fill variant (tintWholeBar=false) expressible
        --     read-free, so both settings work under the factory.
        --   * Gradient border style -- UNFROSTED 2026-07-25 to test the claim behind it.
        --     The frost said gradient "needs a resolved rect to compute its direction+
        --     extent" and so degrades to solid on a secret-anchored slot. Re-reading
        --     Border.lua that looks wrong on two counts: the gradient path measures
        --     NOTHING (it is SetColorTexture + SetGradient on SetPoint-anchored edges --
        --     no GetWidth/GetHeight anywhere in Apply), and Apply's gradient branch is
        --     gated on `style == "GRADIENT" and gradient and CreateColor` with no
        --     _solidOnly check, so the slot's solidOnly flag never blocked the paint.
        --     solidOnly is about secret COLOURS (CreateColor taints on them), which the
        --     gradient pickers are not -- they are static config. secretRect is the flag
        --     that handles rects, and only TEXTURE style needs it. If gradient still
        --     renders solid in game, the cause is something not yet found and the block
        --     should come back with the real reason recorded.
    end

    totalHeight = totalHeight + 8  -- bottom padding
    parent:SetHeight(totalHeight)
    return widgets, totalHeight
end